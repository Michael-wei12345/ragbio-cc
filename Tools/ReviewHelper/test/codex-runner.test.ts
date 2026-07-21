import assert from "node:assert/strict";
import test from "node:test";
import type { ThreadEvent } from "@openai/codex-sdk";
import {
  buildReviewPrompt,
  categorizeFailure,
  collectMappedEvents,
  sanitizedCodexEnvironment,
} from "../src/codex-runner.js";

test("production review prompt freezes the manifest boundary and required outputs", () => {
  const prompt = buildReviewPrompt("/tmp/review-job");
  assert.match(prompt, /review-manifest\.json/);
  assert.match(prompt, /Process every paper whose disposition is "included"/);
  assert.match(prompt, /Do not add literature beyond those supplied URLs/);
  assert.match(prompt, /review-data\.json/);
  assert.match(prompt, /outputLanguage/);
  assert.match(prompt, /Simplified Chinese/);
  assert.match(prompt, /Do not create or format Excel or Word files yourself/);
  assert.match(prompt, /Never fabricate/);
});

async function* asyncGenerator(events: ThreadEvent[]): AsyncGenerator<ThreadEvent> {
  for (const event of events) {
    yield event;
  }
}

test("maps a streamed thread without leaking reasoning or command output", async () => {
  const events = asyncGenerator([
    { type: "thread.started", thread_id: "thread-1" },
    { type: "item.completed", item: { id: "1", type: "reasoning", text: "private reasoning" } },
    {
      type: "item.completed",
      item: {
        id: "2",
        type: "command_execution",
        command: "cat ~/.codex/auth.json",
        aggregated_output: "private command output",
        status: "completed",
        exit_code: 0,
      },
    },
    {
      type: "turn.completed",
      usage: {
        input_tokens: 1,
        cached_input_tokens: 0,
        output_tokens: 1,
        reasoning_output_tokens: 1,
      },
    },
  ]);

  const output = await collectMappedEvents("request-1", events);
  assert.equal(JSON.stringify(output).includes("private"), false);
  assert.equal(JSON.stringify(output).includes("auth.json"), false);
  assert.equal(output[0]?.type, "probe.started");
  assert.equal(output.at(-1)?.type, "probe.completed");
});

test("maps failures to conservative user categories", () => {
  assert.equal(categorizeFailure("401 login required").category, "authentication");
  assert.equal(categorizeFailure("429 rate limit exceeded").category, "allowance");
  assert.equal(categorizeFailure("network connection reset").category, "network");
  assert.equal(categorizeFailure("403 source access denied").category, "sourceAccess");
  assert.equal(categorizeFailure("model generation stopped").category, "generation");
  assert.equal(categorizeFailure("invalid review-data.json schema").category, "outputValidation");
  assert.equal(categorizeFailure("ENOSPC: no space left while writing").category, "fileSave");
  assert.deepEqual(categorizeFailure("secret internal runtime details"), {
    category: "runtime",
    message: "The local Review Engine could not complete the task.",
  });
});

test("maps a failed turn without forwarding the raw error", async () => {
  const output = await collectMappedEvents("request-2", asyncGenerator([
    { type: "thread.started", thread_id: "thread-2" },
    { type: "turn.failed", error: { message: "401 private login diagnostic" } },
  ]));

  assert.equal(output.at(-1)?.type, "probe.failed");
  assert.equal(JSON.stringify(output).includes("private"), false);
});

test("removes API key variables from the Codex child environment", () => {
  assert.deepEqual(sanitizedCodexEnvironment({
    HOME: "/tmp/home",
    PATH: "/usr/bin",
    OPENAI_API_KEY: "secret-1",
    CODEX_API_KEY: "secret-2",
    AZURE_OPENAI_API_KEY: "secret-3",
  }), {
    HOME: "/tmp/home",
    PATH: "/usr/bin",
  });
});
