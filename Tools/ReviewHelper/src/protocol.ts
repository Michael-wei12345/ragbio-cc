export type ProbeMode = "fixture" | "live";

export type HelperCommand =
  | { type: "auth.status"; requestId: string }
  | { type: "auth.login"; requestId: string }
  | {
      type: "probe.start";
      requestId: string;
      mode: ProbeMode;
      workingDirectory: string;
    }
  | { type: "probe.pause"; requestId: string }
  | {
      type: "probe.resume";
      requestId: string;
      threadId: string;
      workingDirectory: string;
    }
  | {
      type: "review.start";
      requestId: string;
      workingDirectory: string;
    }
  | { type: "review.pause"; requestId: string }
  | {
      type: "review.resume";
      requestId: string;
      threadId: string;
      workingDirectory: string;
    };

export type HelperEvent =
  | {
      type: "auth.status";
      requestId: string;
      method: "chatgpt" | "apiKey" | "signedOut";
    }
  | { type: "auth.login.started"; requestId: string }
  | { type: "auth.login.completed"; requestId: string; method: "chatgpt" }
  | { type: "probe.started"; requestId: string; threadId: string }
  | { type: "probe.stage"; requestId: string; stage: string; detail: string }
  | {
      type: "probe.artifacts";
      requestId: string;
      workbookPath: string;
      manuscriptPath: string;
    }
  | { type: "probe.paused"; requestId: string; threadId: string }
  | { type: "probe.completed"; requestId: string; threadId: string }
  | {
      type: "probe.failed";
      requestId: string;
      category:
        | "authentication"
        | "allowance"
        | "network"
        | "sourceAccess"
        | "generation"
        | "outputValidation"
        | "fileSave"
        | "runtime"
        | "protocol";
      message: string;
    };

type JSONRecord = Record<string, unknown>;

const invalidCommand = (): never => {
  throw new Error("Invalid helper command");
};

function isRecord(value: unknown): value is JSONRecord {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function hasExactKeys(record: JSONRecord, keys: readonly string[]): boolean {
  const actual = Object.keys(record).sort();
  const expected = [...keys].sort();
  return actual.length === expected.length && actual.every((key, index) => key === expected[index]);
}

function requireString(record: JSONRecord, key: string): string {
  const value = record[key];
  if (typeof value !== "string" || value.length === 0) {
    return invalidCommand();
  }
  return value;
}

export function parseCommand(line: string): HelperCommand {
  try {
    const value: unknown = JSON.parse(line);
    if (!isRecord(value) || typeof value.type !== "string") {
      return invalidCommand();
    }

    switch (value.type) {
      case "auth.status":
      case "auth.login": {
        if (!hasExactKeys(value, ["type", "requestId"])) {
          return invalidCommand();
        }
        return { type: value.type, requestId: requireString(value, "requestId") };
      }
      case "probe.start": {
        if (!hasExactKeys(value, ["type", "requestId", "mode", "workingDirectory"])) {
          return invalidCommand();
        }
        if (value.mode !== "fixture" && value.mode !== "live") {
          return invalidCommand();
        }
        return {
          type: value.type,
          requestId: requireString(value, "requestId"),
          mode: value.mode,
          workingDirectory: requireString(value, "workingDirectory"),
        };
      }
      case "probe.pause": {
        if (!hasExactKeys(value, ["type", "requestId"])) {
          return invalidCommand();
        }
        return { type: value.type, requestId: requireString(value, "requestId") };
      }
      case "probe.resume": {
        if (!hasExactKeys(value, ["type", "requestId", "threadId", "workingDirectory"])) {
          return invalidCommand();
        }
        return {
          type: value.type,
          requestId: requireString(value, "requestId"),
          threadId: requireString(value, "threadId"),
          workingDirectory: requireString(value, "workingDirectory"),
        };
      }
      case "review.start": {
        if (!hasExactKeys(value, ["type", "requestId", "workingDirectory"])) {
          return invalidCommand();
        }
        return {
          type: value.type,
          requestId: requireString(value, "requestId"),
          workingDirectory: requireString(value, "workingDirectory"),
        };
      }
      case "review.pause": {
        if (!hasExactKeys(value, ["type", "requestId"])) {
          return invalidCommand();
        }
        return { type: value.type, requestId: requireString(value, "requestId") };
      }
      case "review.resume": {
        if (!hasExactKeys(value, ["type", "requestId", "threadId", "workingDirectory"])) {
          return invalidCommand();
        }
        return {
          type: value.type,
          requestId: requireString(value, "requestId"),
          threadId: requireString(value, "threadId"),
          workingDirectory: requireString(value, "workingDirectory"),
        };
      }
      default:
        return invalidCommand();
    }
  } catch {
    return invalidCommand();
  }
}

export function encodeEvent(event: HelperEvent): string {
  return `${JSON.stringify(event)}\n`;
}
