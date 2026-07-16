import { pathToFileURL } from "node:url";
import { createInterface } from "node:readline";
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

class HelperController {
  private activeTask: Promise<void> | undefined;
  private fixtureSession: FixtureSession | undefined;

  constructor(private readonly emit: EventEmitter) {}

  handle(command: HelperCommand): void {
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

    if (command.type === "probe.pause") {
      if (this.activeTask === undefined || this.fixtureSession === undefined) {
        this.fail(command.requestId, "No review probe is running.");
        return;
      }
      this.fixtureSession.paused = true;
      return;
    }

    if (command.type === "probe.resume") {
      const session = this.fixtureSession;
      if (session === undefined || !session.paused || session.threadId !== command.threadId) {
        this.fail(command.requestId, "The review probe cannot be resumed.");
        return;
      }
      const resume = () => {
        session.requestId = command.requestId;
        session.workingDirectory = command.workingDirectory;
        session.paused = false;
        this.launchFixture(session, false);
      };
      if (this.activeTask === undefined) {
        resume();
      } else {
        void this.activeTask.finally(() => setTimeout(resume, 0));
      }
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
