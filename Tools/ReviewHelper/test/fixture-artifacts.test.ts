import assert from "node:assert/strict";
import { mkdtemp, readFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import { createFixtureArtifacts } from "../src/fixture-artifacts.js";
import { runFixtureProbe } from "../src/main.js";
import type { HelperEvent } from "../src/protocol.js";

test("creates openable fixture artifacts with expected document entries", async () => {
  const directory = await mkdtemp(join(tmpdir(), "ragbio-review-"));
  const artifacts = await createFixtureArtifacts(directory);
  const workbook = await readFile(artifacts.workbookPath);
  const manuscript = await readFile(artifacts.manuscriptPath);

  assert.equal(workbook.subarray(0, 2).toString(), "PK");
  assert.equal(manuscript.subarray(0, 2).toString(), "PK");
  assert.equal(workbook.includes(Buffer.from("xl/workbook.xml")), true);
  assert.equal(manuscript.includes(Buffer.from("word/document.xml")), true);
});

test("fixture probe emits deterministic stages and artifact paths", async () => {
  const directory = await mkdtemp(join(tmpdir(), "ragbio-review-"));
  const events: HelperEvent[] = [];

  await runFixtureProbe({
    type: "probe.start",
    requestId: "fixture-1",
    mode: "fixture",
    workingDirectory: directory,
  }, (event) => events.push(event));

  assert.deepEqual(
    events.filter((event) => event.type === "probe.stage").map((event) => event.stage),
    ["prepare", "extract", "generate", "verify"],
  );
  assert.equal(events[0]?.type, "probe.started");
  assert.equal(events.at(-1)?.type, "probe.completed");
  assert.equal(events.some((event) => event.type === "probe.artifacts"), true);
});
