import { Codex, type ThreadEvent } from "@openai/codex-sdk";
import type { HelperEvent } from "./protocol.js";

type EventEmitter = (event: HelperEvent) => void;
type FailureCategory = Extract<HelperEvent, { type: "probe.failed" }>["category"];

export interface SafeFailure {
  category: FailureCategory;
  message: string;
}

const apiKeyEnvironmentNames = new Set([
  "OPENAI_API_KEY",
  "CODEX_API_KEY",
  "AZURE_OPENAI_API_KEY",
]);

export function sanitizedCodexEnvironment(
  source: NodeJS.ProcessEnv = process.env,
): Record<string, string> {
  return Object.fromEntries(
    Object.entries(source).filter(
      (entry): entry is [string, string] => entry[1] !== undefined
        && !apiKeyEnvironmentNames.has(entry[0]),
    ),
  );
}

const probePrompt = `You are running the RagBio Review Engine connection probe.
Work only inside the supplied working directory.
Create probe-status.json containing exactly:
{"status":"connected","executor":"codex-sdk"}
Then reply with exactly: RAGBIO_REVIEW_PROBE_OK`;

const continuationPrompt = "Continue the RagBio Review Engine connection probe from the existing thread.";

export function categorizeFailure(rawMessage: string): SafeFailure {
  const message = rawMessage.toLowerCase();
  if (/authentication|login|sign.?in|\b401\b/.test(message)) {
    return {
      category: "authentication",
      message: "Sign in to ChatGPT to use the local Review Engine.",
    };
  }
  if (/allowance|rate.?limit|usage.?limit|\b429\b|quota/.test(message)) {
    return {
      category: "allowance",
      message: "Your Codex allowance is temporarily unavailable. Try again later.",
    };
  }
  if (/network|connection|offline|dns|timed?.?out/.test(message)) {
    return {
      category: "network",
      message: "The Review Engine could not reach Codex. Check your connection and retry.",
    };
  }
  return {
    category: "runtime",
    message: "The local Review Engine could not complete the task.",
  };
}

export async function mapCodexEvents(
  requestId: string,
  events: AsyncIterable<ThreadEvent>,
  emit: EventEmitter,
  resumedThreadId?: string,
): Promise<string | undefined> {
  let threadId = resumedThreadId;
  for await (const event of events) {
    switch (event.type) {
      case "thread.started":
        threadId = event.thread_id;
        emit({ type: "probe.started", requestId, threadId });
        break;
      case "item.completed":
        if (event.item.type === "command_execution") {
          emit({
            type: "probe.stage",
            requestId,
            stage: "execute",
            detail: "Running a local connection check",
          });
        } else if (event.item.type === "file_change") {
          emit({
            type: "probe.stage",
            requestId,
            stage: "write",
            detail: "Writing the connection result",
          });
        } else if (event.item.type === "agent_message") {
          emit({
            type: "probe.stage",
            requestId,
            stage: "confirm",
            detail: "Confirming the Codex response",
          });
        }
        break;
      case "turn.completed":
        if (threadId === undefined) {
          emit({
            type: "probe.failed",
            requestId,
            category: "protocol",
            message: "Codex completed without a resumable thread.",
          });
        } else {
          emit({ type: "probe.completed", requestId, threadId });
        }
        return threadId;
      case "turn.failed": {
        const failure = categorizeFailure(event.error.message);
        emit({ type: "probe.failed", requestId, ...failure });
        return threadId;
      }
      case "error": {
        const failure = categorizeFailure(event.message);
        emit({ type: "probe.failed", requestId, ...failure });
        return threadId;
      }
      default:
        break;
    }
  }
  return threadId;
}

export async function collectMappedEvents(
  requestId: string,
  events: AsyncIterable<ThreadEvent>,
): Promise<HelperEvent[]> {
  const output: HelperEvent[] = [];
  await mapCodexEvents(requestId, events, (event) => output.push(event));
  return output;
}

const threadOptions = (workingDirectory: string) => ({
  sandboxMode: "workspace-write" as const,
  workingDirectory,
  skipGitRepoCheck: true,
  networkAccessEnabled: true,
  approvalPolicy: "never" as const,
});

export async function runLiveProbe(
  requestId: string,
  workingDirectory: string,
  threadId: string | undefined,
  signal: AbortSignal,
  emit: EventEmitter,
  injectedCodex?: Codex,
): Promise<string | undefined> {
  try {
    const codex = injectedCodex ?? new Codex({ env: sanitizedCodexEnvironment() });
    const thread = threadId === undefined
      ? codex.startThread(threadOptions(workingDirectory))
      : codex.resumeThread(threadId, threadOptions(workingDirectory));
    const streamed = await thread.runStreamed(
      threadId === undefined ? probePrompt : continuationPrompt,
      { signal },
    );
    return await mapCodexEvents(requestId, streamed.events, emit, threadId);
  } catch (error) {
    if (signal.aborted) {
      return threadId;
    }
    const failure = categorizeFailure(error instanceof Error ? error.message : "runtime failure");
    emit({ type: "probe.failed", requestId, ...failure });
    return threadId;
  }
}
