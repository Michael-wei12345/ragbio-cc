import { pathToFileURL } from "node:url";
import { createInterface } from "node:readline";
import { getAuthStatus, startBrowserLogin } from "./codex-auth.js";
import { runLiveProbe, runReview } from "./codex-runner.js";
import { createFixtureArtifacts } from "./fixture-artifacts.js";
import {
  encodeEvent,
  parseCommand,
  type HelperCommand,
  type HelperEvent,
} from "./protocol.js";

type ProbeStartCommand = Extract<HelperCommand, { type: "probe.start" }>;
type EventEmitter = (event: HelperEvent) => void;

const fixtureStages = [
  ["prepare", "Preparing the local review workspace"],
  ["extract", "Reading the fixture source manifest"],
  ["generate", "Generating the workbook and manuscript"],
  ["verify", "Verifying generated artifacts"],
] as const;

interface FixtureRunOptions {
  emittedStages?: Set<string>;
  isPaused?: () => boolean;
  delay?: () => Promise<void>;
  emitStarted?: boolean;
  threadId?: string;
}

export async function runFixtureProbe(
  command: ProbeStartCommand,
  emit: EventEmitter,
  options: FixtureRunOptions = {},
): Promise<boolean> {
  const threadId = options.threadId ?? `fixture-${command.requestId}`;
  const emittedStages = options.emittedStages ?? new Set<string>();
  const isPaused = options.isPaused ?? (() => false);
  const delay = options.delay ?? (async () => {});
  if (options.emitStarted !== false) {
    emit({ type: "probe.started", requestId: command.requestId, threadId });
  }

  for (const [stage, detail] of fixtureStages) {
    if (emittedStages.has(stage)) {
      continue;
    }
    if (isPaused()) {
      return false;
    }
    emit({ type: "probe.stage", requestId: command.requestId, stage, detail });
    emittedStages.add(stage);
    await delay();
  }

  if (isPaused()) {
    return false;
  }

  const artifacts = await createFixtureArtifacts(command.workingDirectory);
  emit({
    type: "probe.artifacts",
    requestId: command.requestId,
    workbookPath: artifacts.workbookPath,
    manuscriptPath: artifacts.manuscriptPath,
  });
  emit({ type: "probe.completed", requestId: command.requestId, threadId });
  return true;
}

interface FixtureSession {
  requestId: string;
  threadId: string;
  workingDirectory: string;
  emittedStages: Set<string>;
  paused: boolean;
}

interface LiveSession {
  requestId: string;
  threadId?: string;
  workingDirectory: string;
  paused: boolean;
}

interface ReviewSession {
  requestId: string;
  threadId?: string;
  workingDirectory: string;
  paused: boolean;
}

class HelperController {
  private activeTask: Promise<void> | undefined;
  private activeAbortController: AbortController | undefined;
  private fixtureSession: FixtureSession | undefined;
  private liveSession: LiveSession | undefined;
  private reviewSession: ReviewSession | undefined;

  constructor(private readonly emit: EventEmitter) {}

  handle(command: HelperCommand): void {
    if (command.type === "auth.status") {
      void getAuthStatus().then((method) => {
        this.emit({ type: "auth.status", requestId: command.requestId, method });
      }).catch(() => {
        this.emit({
          type: "probe.failed",
          requestId: command.requestId,
          category: "runtime",
          message: "The local Codex runtime could not report sign-in status.",
        });
      });
      return;
    }

    if (command.type === "auth.login") {
      void startBrowserLogin(command.requestId, this.emit).then((method) => {
        if (method !== "chatgpt") {
          this.emit({ type: "auth.status", requestId: command.requestId, method });
        }
      }).catch(() => {
        this.emit({
          type: "probe.failed",
          requestId: command.requestId,
          category: "authentication",
          message: "ChatGPT sign-in did not complete.",
        });
      });
      return;
    }

    if (command.type === "probe.start" && command.mode === "fixture") {
      if (this.activeTask !== undefined) {
        this.fail(command.requestId, "A review probe is already running.");
        return;
      }
      const session: FixtureSession = {
        requestId: command.requestId,
        threadId: `fixture-${command.requestId}`,
        workingDirectory: command.workingDirectory,
        emittedStages: new Set<string>(),
        paused: false,
      };
      this.fixtureSession = session;
      this.launchFixture(session, true);
      return;
    }

    if (command.type === "probe.start" && command.mode === "live") {
      if (this.activeTask !== undefined) {
        this.fail(command.requestId, "A review probe is already running.");
        return;
      }
      const session: LiveSession = {
        requestId: command.requestId,
        workingDirectory: command.workingDirectory,
        paused: false,
      };
      this.liveSession = session;
      this.launchLive(session, false);
      return;
    }

    if (command.type === "review.start") {
      if (this.activeTask !== undefined) {
        this.fail(command.requestId, "A review is already running.");
        return;
      }
      const session: ReviewSession = {
        requestId: command.requestId,
        workingDirectory: command.workingDirectory,
        paused: false,
      };
      this.reviewSession = session;
      this.launchReview(session, false);
      return;
    }

    if (command.type === "probe.pause") {
      if (this.activeTask === undefined) {
        this.fail(command.requestId, "No review probe is running.");
        return;
      }
      if (this.fixtureSession !== undefined) {
        this.fixtureSession.paused = true;
      } else if (this.liveSession !== undefined) {
        this.liveSession.paused = true;
        this.activeAbortController?.abort();
      } else {
        this.fail(command.requestId, "No review probe is running.");
      }
      return;
    }

    if (command.type === "review.pause") {
      if (this.activeTask === undefined || this.reviewSession === undefined) {
        this.fail(command.requestId, "No review is running.");
        return;
      }
      this.reviewSession.paused = true;
      this.activeAbortController?.abort();
      return;
    }

    if (command.type === "probe.resume") {
      const fixture = this.fixtureSession;
      if (fixture !== undefined && fixture.paused && fixture.threadId === command.threadId) {
        const resume = () => {
          fixture.requestId = command.requestId;
          fixture.workingDirectory = command.workingDirectory;
          fixture.paused = false;
          this.launchFixture(fixture, false);
        };
        this.afterActiveTask(resume);
        return;
      }

      const existingLive = this.liveSession;
      const live = existingLive?.threadId === command.threadId
        ? existingLive
        : existingLive === undefined && !command.threadId.startsWith("fixture-")
          ? {
              requestId: command.requestId,
              threadId: command.threadId,
              workingDirectory: command.workingDirectory,
              paused: true,
            }
          : undefined;
      if (live === undefined || (!live.paused && this.activeTask !== undefined)) {
        this.fail(command.requestId, "The review probe cannot be resumed.");
        return;
      }
      this.liveSession = live;
      const resume = () => {
        live.requestId = command.requestId;
        live.workingDirectory = command.workingDirectory;
        live.paused = false;
        this.launchLive(live, true);
      };
      this.afterActiveTask(resume);
      return;
    }

    if (command.type === "review.resume") {
      const existing = this.reviewSession;
      const review = existing?.threadId === command.threadId
        ? existing
        : existing === undefined
          ? {
              requestId: command.requestId,
              threadId: command.threadId,
              workingDirectory: command.workingDirectory,
              paused: true,
            }
          : undefined;
      if (review === undefined || (!review.paused && this.activeTask !== undefined)) {
        this.fail(command.requestId, "The review cannot be resumed.");
        return;
      }
      this.reviewSession = review;
      const resume = () => {
        review.requestId = command.requestId;
        review.workingDirectory = command.workingDirectory;
        review.paused = false;
        this.launchReview(review, true);
      };
      this.afterActiveTask(resume);
      return;
    }

    this.fail(command.requestId, "This helper command is not available yet.");
  }

  private launchFixture(session: FixtureSession, emitStarted: boolean): void {
    const command: ProbeStartCommand = {
      type: "probe.start",
      requestId: session.requestId,
      mode: "fixture",
      workingDirectory: session.workingDirectory,
    };
    this.activeTask = runFixtureProbe(command, this.emit, {
      emittedStages: session.emittedStages,
      emitStarted,
      threadId: session.threadId,
      isPaused: () => session.paused,
      delay: () => new Promise((resolve) => setTimeout(resolve, 40)),
    }).then((completed) => {
      if (!completed) {
        this.emit({
          type: "probe.paused",
          requestId: session.requestId,
          threadId: session.threadId,
        });
      } else {
        this.fixtureSession = undefined;
      }
    }).catch(() => {
      this.fail(session.requestId, "The fixture probe failed.");
      this.fixtureSession = undefined;
    }).finally(() => {
      this.activeTask = undefined;
    });
  }

  private launchLive(session: LiveSession, resume: boolean): void {
    const abortController = new AbortController();
    this.activeAbortController = abortController;
    let terminalEvent = false;
    const emit: EventEmitter = (event) => {
      if (event.type === "probe.started") {
        session.threadId = event.threadId;
      }
      if (event.type === "probe.completed" || event.type === "probe.failed") {
        terminalEvent = true;
      }
      this.emit(event);
    };

    this.activeTask = runLiveProbe(
      session.requestId,
      session.workingDirectory,
      resume ? session.threadId : undefined,
      abortController.signal,
      emit,
    ).then((threadId) => {
      if (threadId !== undefined) {
        session.threadId = threadId;
      }
      if (session.paused) {
        if (session.threadId === undefined) {
          this.fail(session.requestId, "Codex paused before creating a resumable thread.");
          this.liveSession = undefined;
        } else {
          this.emit({
            type: "probe.paused",
            requestId: session.requestId,
            threadId: session.threadId,
          });
        }
      } else if (terminalEvent) {
        this.liveSession = undefined;
      } else {
        this.fail(session.requestId, "The live review probe ended unexpectedly.");
        this.liveSession = undefined;
      }
    }).finally(() => {
      this.activeAbortController = undefined;
      this.activeTask = undefined;
    });
  }

  private launchReview(session: ReviewSession, resume: boolean): void {
    const abortController = new AbortController();
    this.activeAbortController = abortController;
    let terminalEvent = false;
    const emit: EventEmitter = (event) => {
      if (event.type === "probe.started") {
        session.threadId = event.threadId;
      }
      if (event.type === "probe.completed" || event.type === "probe.failed") {
        terminalEvent = true;
      }
      this.emit(event);
    };

    this.activeTask = runReview(
      session.requestId,
      session.workingDirectory,
      resume ? session.threadId : undefined,
      abortController.signal,
      emit,
    ).then((threadId) => {
      if (threadId !== undefined) {
        session.threadId = threadId;
      }
      if (session.paused) {
        if (session.threadId === undefined) {
          this.fail(session.requestId, "Codex paused before creating a resumable review thread.");
          this.reviewSession = undefined;
        } else {
          this.emit({
            type: "probe.paused",
            requestId: session.requestId,
            threadId: session.threadId,
          });
        }
      } else if (terminalEvent) {
        this.reviewSession = undefined;
      } else {
        this.fail(session.requestId, "The review ended unexpectedly.");
        this.reviewSession = undefined;
      }
    }).finally(() => {
      this.activeAbortController = undefined;
      this.activeTask = undefined;
    });
  }

  private afterActiveTask(action: () => void): void {
    if (this.activeTask === undefined) {
      action();
    } else {
      void this.activeTask.finally(() => setTimeout(action, 0));
    }
  }

  private fail(requestId: string, message: string): void {
    this.emit({ type: "probe.failed", requestId, category: "protocol", message });
  }
}

export async function runCommandLoop(): Promise<void> {
  const lines = createInterface({ input: process.stdin, crlfDelay: Infinity });
  const emit: EventEmitter = (event) => process.stdout.write(encodeEvent(event));
  const controller = new HelperController(emit);

  for await (const line of lines) {
    if (line.trim().length === 0) {
      continue;
    }
    try {
      controller.handle(parseCommand(line));
    } catch {
      emit({
        type: "probe.failed",
        requestId: "unknown",
        category: "protocol",
        message: "Invalid helper command",
      });
    }
  }
}

const entryPoint = process.argv[1];
if (entryPoint !== undefined && import.meta.url === pathToFileURL(entryPoint).href) {
  await runCommandLoop();
}
