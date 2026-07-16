import assert from "node:assert/strict";
import { mkdtemp, readFile, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import ExcelJS from "exceljs";
import { buildArtifacts } from "../workflow/scripts/build_artifacts.mjs";

const expectedSheets = [
  "README",
  "Study characteristics",
  "Inclusion-exclusion criteria",
  "Total",
  "R",
  "R, Distant Recurrence",
  "Other Data",
  "Risk of bias",
  "Preliminary synthesis",
  "GRADE",
  "Codebook",
  "Source audit",
];

test("builds deterministic review artifacts with the full workbook contract", async () => {
  const directory = await mkdtemp(join(tmpdir(), "ragbio-artifacts-"));
  const manifestPath = join(directory, "review-manifest.json");
  const dataPath = join(directory, "review-data.json");
  await writeFile(manifestPath, JSON.stringify({
    query: "Example intervention review",
    papers: [
      { order: 1, workID: "W1", title: "Primary report", venue: "Example Journal", publicationYear: 2024, sourceURL: "https://doi.org/10.1000/example", disposition: "included" },
      { order: 2, workID: "W2", title: "Unassessed report", venue: "Other Journal", publicationYear: 2023, sourceURL: "https://example.org/two", disposition: "included" },
    ],
  }));
  await writeFile(dataPath, JSON.stringify({
    topic: "Example intervention review",
    researchQuestion: "What is the supplied evidence?",
    pico: { population: "Adults", interventionExposure: "Intervention", comparator: "Control", outcomes: "Response" },
    abstract: { background: "Background", objective: "Objective", methods: "Methods", results: "Results", conclusions: "Conclusion" },
    studyCharacteristics: [{ recordID: "W1", studyID: "S1", title: "Primary report", design: "Randomized trial", sampleSize: 100 }],
    decisions: [{ recordID: "W1", studyID: "S1", title: "Primary report", disposition: "Include", poolingEligibility: "Yes", reason: "Primary comparative evidence" }],
    sourceAudit: [{ recordID: "W1", sourceType: "Full text", typeOfSource: "Randomized trial", title: "Primary report", url: "https://doi.org/10.1000/example", status: "Include", confidence: "High" }],
    analysisRows: [{ studyID: "S1", recordID: "W1", outcomeFamily: "Response", events: 40, n: 50, includeInPool: "Yes", poolSet: "response-1" }],
    distantRows: [],
    otherData: [],
    riskOfBias: [{ studyID: "S1", tool: "RoB 2", domain: "Randomization", judgment: "Some concerns", rationale: "Insufficient detail" }],
    synthesis: [{ section: "Response", finding: "One supplied study reported response", evidenceBase: "S1", extractionNote: "Verify before publication" }],
    grade: [{ outcome: "Response", studyCount: 1, certainty: "Very low", explanation: "Single supplied study" }],
    readiness: [{ item: "Clear PICO", status: "Yes", note: "Defined from the request" }],
    references: [{ id: "W1", citation: "Primary report. Example Journal. 2024.", url: "https://doi.org/10.1000/example", doi: "10.1000/example" }],
    manuscript: {
      introduction: ["Introduction text."], methods: ["Methods text."], results: ["Results text."],
      discussion: ["Discussion text."], conclusion: ["Conclusion text."], limitations: ["Limitations text."],
      dataAvailability: "See accompanying workbook.",
    },
  }));

  const artifacts = await buildArtifacts(dataPath, manifestPath, directory);
  const workbookBytes = await readFile(artifacts.workbookPath);
  const manuscriptBytes = await readFile(artifacts.manuscriptPath);
  assert.equal(workbookBytes.subarray(0, 2).toString(), "PK");
  assert.equal(manuscriptBytes.subarray(0, 2).toString(), "PK");

  const workbook = new ExcelJS.Workbook();
  await workbook.xlsx.readFile(artifacts.workbookPath);
  assert.deepEqual(workbook.worksheets.map((sheet) => sheet.name), expectedSheets);
  const audit = workbook.getWorksheet("Source audit");
  assert.equal(audit?.rowCount, 3);
  assert.equal(audit?.getRow(3).getCell(1).value, "W2");
  assert.match(String(audit?.getRow(3).getCell(10).value), /not assessed/i);
  assert.equal(workbook.getWorksheet("R")?.getRow(2).getCell(6).value, 40);
});
