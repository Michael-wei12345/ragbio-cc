import assert from "node:assert/strict";
import { EventEmitter } from "node:events";
import { PassThrough } from "node:stream";
import test from "node:test";
import {
  getAuthStatus,
  resolveCodexCLIPath,
  startBrowserLogin,
  type SpawnAdapter,
  type SpawnInvocation,
} from "../src/codex-auth.js";
import type { HelperEvent } from "../src/protocol.js";

function fakeSpawn(output: string, exitCode = 0, stderrOutput = "private child diagnostic"): {
  calls: SpawnInvocation[];
  spawn: SpawnAdapter;
} {
  const calls: SpawnInvocation[] = [];
  return {
    calls,
    spawn: (command) => {
      calls.push(command);
      const child = new EventEmitter() as ReturnType<SpawnAdapter>;
      const stdout = new PassThrough();
      const stderr = new PassThrough();
      Object.assign(child, { stdout, stderr });
      queueMicrotask(() => {
        stdout.end(output);
        stderr.end(stderrOutput);
        child.emit("close", exitCode, null);
      });
      return child;
    },
  };
}

test("auth status invokes the pinned CLI without a login shell", async () => {
  const fake = fakeSpawn("Logged in using ChatGPT\n");
  const method = await getAuthStatus(fake.spawn);

  assert.equal(method, "chatgpt");
  assert.equal(fake.calls.length, 1);
  assert.equal(fake.calls[0]?.executable, process.execPath);
  assert.deepEqual(fake.calls[0]?.arguments, [resolveCodexCLIPath(), "login", "status"]);
});

test("auth status maps API key and signed-out states", async () => {
  assert.equal(await getAuthStatus(fakeSpawn("Logged in using an API key").spawn), "apiKey");
  assert.equal(await getAuthStatus(fakeSpawn("Not logged in", 1).spawn), "signedOut");
  assert.equal(await getAuthStatus(fakeSpawn("", 0, "Logged in using ChatGPT").spawn), "chatgpt");
});

test("browser login emits only safe lifecycle events", async () => {
  const fake = fakeSpawn("Logged in using ChatGPT\n");
  const events: HelperEvent[] = [];
  const method = await startBrowserLogin("login-1", (event) => events.push(event), fake.spawn);

  assert.equal(method, "chatgpt");
  assert.deepEqual(events, [
    { type: "auth.login.started", requestId: "login-1" },
    { type: "auth.login.completed", requestId: "login-1", method: "chatgpt" },
  ]);
  assert.equal(JSON.stringify(events).includes("private"), false);
  assert.deepEqual(fake.calls[0]?.arguments, [resolveCodexCLIPath(), "login"]);
  assert.deepEqual(fake.calls[1]?.arguments, [resolveCodexCLIPath(), "login", "status"]);
});
