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

export async function runFixtureProbe(
  command: ProbeStartCommand,
  emit: EventEmitter,
): Promise<void> {
  const threadId = `fixture-${command.requestId}`;
  emit({ type: "probe.started", requestId: command.requestId, threadId });

  emit({
    type: "probe.stage",
    requestId: command.requestId,
    stage: "prepare",
    detail: "Preparing the local review workspace",
  });
  emit({
    type: "probe.stage",
    requestId: command.requestId,
    stage: "extract",
    detail: "Reading the fixture source manifest",
  });
  emit({
    type: "probe.stage",
    requestId: command.requestId,
    stage: "generate",
    detail: "Generating the workbook and manuscript",
  });

  const artifacts = await createFixtureArtifacts(command.workingDirectory);
  emit({
    type: "probe.artifacts",
    requestId: command.requestId,
    workbookPath: artifacts.workbookPath,
    manuscriptPath: artifacts.manuscriptPath,
  });
  emit({
    type: "probe.stage",
    requestId: command.requestId,
    stage: "verify",
    detail: "Verifying generated artifacts",
  });
  emit({ type: "probe.completed", requestId: command.requestId, threadId });
}

async function dispatch(command: HelperCommand, emit: EventEmitter): Promise<void> {
  if (command.type === "probe.start" && command.mode === "fixture") {
    await runFixtureProbe(command, emit);
    return;
  }

  emit({
    type: "probe.failed",
    requestId: command.requestId,
    category: "protocol",
    message: "This helper command is not available yet.",
  });
}

export async function runCommandLoop(): Promise<void> {
  const lines = createInterface({ input: process.stdin, crlfDelay: Infinity });
  const emit: EventEmitter = (event) => process.stdout.write(encodeEvent(event));

  for await (const line of lines) {
    if (line.trim().length === 0) {
      continue;
    }
    try {
      await dispatch(parseCommand(line), emit);
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
