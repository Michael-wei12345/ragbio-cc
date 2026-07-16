import assert from "node:assert/strict";
import test from "node:test";
import { encodeEvent, parseCommand } from "../src/protocol.js";

test("parses a fixture probe start command", () => {
  assert.deepEqual(
    parseCommand(JSON.stringify({
      type: "probe.start",
      requestId: "request-1",
      mode: "fixture",
      workingDirectory: "/tmp/ragbio-review-probe",
    })),
    {
      type: "probe.start",
      requestId: "request-1",
      mode: "fixture",
      workingDirectory: "/tmp/ragbio-review-probe",
    },
  );
});

test("parses a probe resume command", () => {
  assert.deepEqual(
    parseCommand(JSON.stringify({
      type: "probe.resume",
      requestId: "request-2",
      threadId: "thread-1",
      workingDirectory: "/tmp/ragbio-review-probe",
    })),
    {
      type: "probe.resume",
      requestId: "request-2",
      threadId: "thread-1",
      workingDirectory: "/tmp/ragbio-review-probe",
    },
  );
});

test("parses production review commands", () => {
  assert.deepEqual(
    parseCommand(JSON.stringify({
      type: "review.start",
      requestId: "review-1",
      workingDirectory: "/tmp/review",
    })),
    {
      type: "review.start",
      requestId: "review-1",
      workingDirectory: "/tmp/review",
    },
  );
  assert.deepEqual(
    parseCommand(JSON.stringify({
      type: "review.resume",
      requestId: "review-2",
      threadId: "thread-1",
      workingDirectory: "/tmp/review",
    })),
    {
      type: "review.resume",
      requestId: "review-2",
      threadId: "thread-1",
      workingDirectory: "/tmp/review",
    },
  );
});

test("rejects unknown command fields", () => {
  assert.throws(() => parseCommand(JSON.stringify({
    type: "probe.pause",
    requestId: "request-1",
    secret: "must-not-pass",
  })), /^Error: Invalid helper command$/);
});

test("rejects malformed JSON without including its contents", () => {
  const secret = "private-token-value";
  assert.throws(
    () => parseCommand(`{\"type\":\"probe.pause\",\"secret\":\"${secret}\"`),
    (error: unknown) => error instanceof Error
      && error.message === "Invalid helper command"
      && !error.message.includes(secret),
  );
});

test("encodes exactly one JSONL event", () => {
  const line = encodeEvent({
    type: "probe.started",
    requestId: "request-1",
    threadId: "thread-1",
  });
  assert.equal(line.endsWith("\n"), true);
  assert.equal(line.endsWith("\n\n"), false);
  assert.deepEqual(JSON.parse(line), {
    type: "probe.started",
    requestId: "request-1",
    threadId: "thread-1",
  });
});
