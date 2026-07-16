import { spawn as nodeSpawn, type ChildProcess } from "node:child_process";
import { createRequire } from "node:module";
import type { HelperEvent } from "./protocol.js";

export type AuthMethod = "chatgpt" | "apiKey" | "signedOut";

export interface SpawnInvocation {
  executable: string;
  arguments: string[];
}

export type SpawnAdapter = (invocation: SpawnInvocation) => ChildProcess;
type EventEmitter = (event: HelperEvent) => void;

const defaultSpawn: SpawnAdapter = ({ executable, arguments: arguments_ }) => nodeSpawn(
  executable,
  arguments_,
  { stdio: ["ignore", "pipe", "pipe"] },
);

export function resolveCodexCLIPath(): string {
  return createRequire(import.meta.url).resolve("@openai/codex/bin/codex.js");
}

async function runCLI(arguments_: string[], spawn: SpawnAdapter): Promise<{
  exitCode: number;
  statusOutput: string;
}> {
  const child = spawn({
    executable: process.execPath,
    arguments: [resolveCodexCLIPath(), ...arguments_],
  });
  let statusOutput = "";
  const appendStatusOutput = (chunk: string) => {
    if (statusOutput.length < 8_192) {
      statusOutput += chunk.slice(0, 8_192 - statusOutput.length);
    }
  };
  child.stdout?.setEncoding("utf8");
  child.stdout?.on("data", appendStatusOutput);
  child.stderr?.setEncoding("utf8");
  child.stderr?.on("data", appendStatusOutput);

  return await new Promise((resolve, reject) => {
    child.once("error", () => reject(new Error("The local Codex runtime could not start.")));
    child.once("close", (code) => resolve({ exitCode: code ?? 1, statusOutput }));
  });
}

export async function getAuthStatus(spawn: SpawnAdapter = defaultSpawn): Promise<AuthMethod> {
  const result = await runCLI(["login", "status"], spawn);
  if (result.exitCode !== 0) {
    return "signedOut";
  }

  const status = result.statusOutput.toLowerCase();
  if (status.includes("chatgpt")) {
    return "chatgpt";
  }
  if (status.includes("api key") || status.includes("api-key")) {
    return "apiKey";
  }
  return "signedOut";
}

export async function startBrowserLogin(
  requestId: string,
  emit: EventEmitter,
  spawn: SpawnAdapter = defaultSpawn,
): Promise<AuthMethod> {
  emit({ type: "auth.login.started", requestId });
  const login = await runCLI(["login"], spawn);
  if (login.exitCode !== 0) {
    throw new Error("ChatGPT sign-in did not complete.");
  }

  const method = await getAuthStatus(spawn);
  if (method === "chatgpt") {
    emit({ type: "auth.login.completed", requestId, method: "chatgpt" });
  }
  return method;
}
