#!/usr/bin/env node

import { readFile, writeFile, mkdir } from "node:fs/promises";
import { resolve } from "node:path";
import { pathToFileURL } from "node:url";
import ExcelJS from "exceljs";
import {
  AlignmentType,
  convertInchesToTwip,
  Document,
  HeadingLevel,
  Packer,
  Paragraph,
  TextRun,
} from "docx";

const workbookName = "RagBio Review Engine.xlsx";
const manuscriptName = "RagBio Review Engine.docx";

const requiredSheets = [
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

const asArray = (value) => Array.isArray(value) ? value : [];
const asObject = (value) => value !== null && typeof value === "object" && !Array.isArray(value) ? value : {};
const stringValue = (value) => {
  if (value === null || value === undefined) return "";
  if (Array.isArray(value)) return value.map(stringValue).filter(Boolean).join("; ");
  if (typeof value === "object") return JSON.stringify(value);
  return String(value);
};
const cellValue = (value) => {
  if (value === null || value === undefined) return "";
  if (typeof value === "number" || typeof value === "boolean") return value;
  return stringValue(value);
};
const first = (row, keys, fallback = "") => {
  for (const key of keys) {
    if (row[key] !== undefined && row[key] !== null && row[key] !== "") return row[key];
  }
  return fallback;
};

function normalizedManifestPapers(manifest) {
  return asArray(manifest.papers).map((paper, index) => ({
    order: paper.order ?? index + 1,
    workID: stringValue(paper.workID),
    title: stringValue(paper.title),
    venue: stringValue(paper.venue),
    publicationYear: paper.publicationYear ?? "",
    sourceURL: stringValue(paper.sourceURL),
    originalURL: stringValue(paper.originalURL),
    disposition: stringValue(paper.disposition),
    duplicateOfOrder: paper.duplicateOfOrder ?? "",
  }));
}

function reconcileAudit(data, manifest) {
  const supplied = asArray(data.sourceAudit).map((row) => ({ ...asObject(row) }));
  const byKey = new Map();
  for (const row of supplied) {
    const key = stringValue(first(row, ["recordID", "recordId", "workID", "workId", "url", "sourceURL"])).toLowerCase();
    if (key) byKey.set(key, row);
  }
  return normalizedManifestPapers(manifest).map((paper) => {
    const candidates = [paper.workID, paper.sourceURL, paper.originalURL].filter(Boolean).map((value) => value.toLowerCase());
    const existing = candidates.map((key) => byKey.get(key)).find(Boolean) ?? {};
    return {
      recordID: first(existing, ["recordID", "recordId", "workID", "workId"], paper.workID || `record-${paper.order}`),
      sourceType: first(existing, ["sourceType", "accessStatus"], paper.disposition === "included" ? "Not assessed" : paper.disposition),
      typeOfSource: first(existing, ["typeOfSource", "publicationType", "studyDesign"], "Not assessed"),
      title: first(existing, ["title"], paper.title),
      year: first(existing, ["year", "publicationYear"], paper.publicationYear),
      journal: first(existing, ["journal", "venue"], paper.venue),
      url: first(existing, ["url", "sourceURL"], paper.sourceURL || paper.originalURL),
      doi: first(existing, ["doi", "DOI"]),
      status: first(existing, ["status", "disposition", "decision"], paper.disposition === "included" ? "Not assessed" : paper.disposition),
      notes: first(existing, ["notes", "note", "reason"], paper.disposition === "included" && Object.keys(existing).length === 0 ? "Manifest source was not assessed by the Review Engine." : ""),
      confidence: first(existing, ["confidence", "extractionConfidence"], "Not assessed"),
      manifestOrder: paper.order,
    };
  });
}

function normalizeRows(rows) {
  return asArray(rows).map((row) => ({ ...asObject(row) }));
}

const definitions = [
  ["recordID", "Stable identifier for a supplied report."],
  ["studyID", "Identifier grouping reports from the same underlying study."],
  ["Source type", "How the source was accessed, not its publication design."],
  ["Type of source", "Publication or study design classification."],
  ["disposition", "Include, Supplementary, or Exclude at report/study level."],
  ["poolingEligibility", "Endpoint-level Yes, No, or Maybe decision; separate from inclusion."],
  ["poolSet", "Identifier for clinically comparable estimates eligible for one synthesis."],
  ["overlapGroup", "Identifier for overlapping cohorts or companion reports."],
  ["events", "Number of participants or units with the stated event."],
  ["n", "Denominator corresponding to events."],
  ["extractionConfidence", "Confidence in the extracted value based on accessible source evidence."],
];

function addSheet(workbook, name, columns, rows, note) {
  const sheet = workbook.addWorksheet(name, { views: [{ state: "frozen", ySplit: 1 }] });
  sheet.columns = columns.map(({ header, key, width = 18 }) => ({ header, key, width }));
  for (const row of rows) {
    const normalized = {};
    for (const column of columns) normalized[column.key] = cellValue(row[column.key]);
    sheet.addRow(normalized);
  }
  const header = sheet.getRow(1);
  header.font = { bold: true, color: { argb: "FFFFFFFF" } };
  header.fill = { type: "pattern", pattern: "solid", fgColor: { argb: "FF275D8C" } };
  header.alignment = { vertical: "middle", horizontal: "center", wrapText: true };
  header.height = 30;
  sheet.autoFilter = { from: { row: 1, column: 1 }, to: { row: 1, column: Math.max(1, columns.length) } };
  sheet.eachRow((row, rowNumber) => {
    if (rowNumber > 1) {
      row.alignment = { vertical: "top", wrapText: true };
      if (rowNumber % 2 === 0) row.fill = { type: "pattern", pattern: "solid", fgColor: { argb: "FFF1F6FA" } };
    }
    row.eachCell((cell) => {
      cell.border = {
        top: { style: "thin", color: { argb: "FFD8E0E7" } },
        left: { style: "thin", color: { argb: "FFD8E0E7" } },
        bottom: { style: "thin", color: { argb: "FFD8E0E7" } },
        right: { style: "thin", color: { argb: "FFD8E0E7" } },
      };
    });
  });
  if (rows.length === 0 && note) sheet.addRow(Object.fromEntries([[columns[0].key, note]]));
  return sheet;
}

function genericColumns(rows, preferred = []) {
  const seen = new Set(preferred);
  for (const row of rows) for (const key of Object.keys(row)) seen.add(key);
  const keys = [...seen];
  if (keys.length === 0) keys.push("note");
  return keys.map((key) => ({
    header: key.replace(/([a-z])([A-Z])/g, "$1 $2").replace(/^./, (letter) => letter.toUpperCase()),
    key,
    width: /note|reason|finding|rationale|abstract|outcome|population|intervention|comparator|title/i.test(key) ? 34 : 18,
  }));
}

function decisionCounts(decisions, audit) {
  const counts = { Included: 0, Supplementary: 0, Excluded: 0, Duplicate: 0, Inaccessible: 0, "Not assessed": 0 };
  const source = decisions.length > 0 ? decisions : audit;
  for (const row of source) {
    const value = stringValue(first(row, ["disposition", "decision", "status"])).toLowerCase();
    if (value.includes("supplement")) counts.Supplementary += 1;
    else if (value.includes("exclude")) counts.Excluded += 1;
    else if (value.includes("duplicate")) counts.Duplicate += 1;
    else if (value.includes("inaccessible") || value.includes("unavailable")) counts.Inaccessible += 1;
    else if (value.includes("include")) counts.Included += 1;
    else counts["Not assessed"] += 1;
  }
  return Object.entries(counts).map(([category, count]) => ({ category, count }));
}

function paragraph(text, options = {}) {
  return new Paragraph({
    ...options,
    children: [new TextRun({ text: stringValue(text), bold: options.bold ?? false })],
  });
}

function heading(text, level = HeadingLevel.HEADING_1) {
  return new Paragraph({ text, heading: level, keepNext: true });
}

function proseParagraphs(value, fallback) {
  const values = Array.isArray(value) ? value : value ? [value] : [];
  return (values.length ? values : [fallback]).map((item) => paragraph(item, { spacing: { after: 180 }, alignment: AlignmentType.JUSTIFIED }));
}

function manuscriptCopy(manifest) {
  if (manifest.outputLanguage === "simplifiedChinese") {
    return {
      titleFallback: "RagBio 用户指定来源证据综述",
      draftNotice: "本草稿仅基于用户在 RagBio 中选择的 URL 生成；发表前必须由专家核验。",
      headings: {
        abstract: "摘要", introduction: "引言", methods: "方法", results: "结果",
        discussion: "讨论", limitations: "局限性", conclusion: "结论",
        dataAvailability: "数据可用性", references: "参考文献",
        readiness: "附录：综述准备度检查表",
      },
      abstractLabels: ["背景", "目的", "方法", "结果", "结论"],
      missingAbstract: "生成的提取结果中未报告。",
      introductionFallback: "本综述旨在回答所陈述的研究问题，并仅分析用户提供的证据集合。",
      evidenceBoundary: "证据来源边界：仅评估用户在 RagBio 中选择并记录于不可变输入清单的 URL，未进行额外文献检索。",
      methodsFallback: "基于可访问的指定记录评估来源获取、研究资格、数据提取、偏倚风险和证据综合；未假定任何未记录的系统综述程序。",
      resultsFallback: "结果仅限于随附工作簿中记录的发现。",
      discussionFallback: "应在用户指定来源的边界内解释这些发现，并对照原始报告进行核验。",
      limitationsFallback: "不能声称已完成全面多数据库检索、方案注册、双人独立筛选或其他未记录的系统综述标准。",
      conclusionFallback: "不得推断超出已提取指定证据范围的结论。",
      dataAvailabilityFallback: "结构化提取和来源审计数据见随附的 RagBio Excel 工作簿。",
      missingReferences: "未生成完整参考文献列表；请查阅 Excel 工作簿中的 Source audit 表。",
      description: "用户指定来源的系统综述草稿",
    };
  }
  return {
    titleFallback: "RagBio Supplied-Source Evidence Review",
    draftNotice: "Draft generated from user-selected RagBio URLs; expert verification is required before publication.",
    headings: {
      abstract: "Abstract", introduction: "Introduction", methods: "Methods", results: "Results",
      discussion: "Discussion", limitations: "Limitations", conclusion: "Conclusion",
      dataAvailability: "Data Availability", references: "References",
      readiness: "Appendix: Review Readiness Checklist",
    },
    abstractLabels: ["Background", "Objective", "Methods", "Results", "Conclusions"],
    missingAbstract: "Not reported in the generated extraction.",
    introductionFallback: "The supplied evidence set was reviewed to address the stated research question.",
    evidenceBoundary: "Evidence source boundary: only URLs selected by the user in RagBio and recorded in the immutable input manifest were assessed. No additional literature search was performed.",
    methodsFallback: "Source access, eligibility, extraction, risk of bias, and synthesis were assessed from the accessible supplied records. Undocumented systematic-review procedures were not assumed.",
    resultsFallback: "Results are limited to findings captured in the accompanying workbook.",
    discussionFallback: "The findings should be interpreted within the supplied-source boundary and verified against the original reports.",
    limitationsFallback: "A comprehensive multi-database search, registered protocol, dual independent screening, and other undocumented systematic-review standards cannot be claimed.",
    conclusionFallback: "No conclusion beyond the extracted supplied evidence should be inferred.",
    dataAvailabilityFallback: "Structured extraction and source-audit data are provided in the accompanying RagBio Excel workbook.",
    missingReferences: "No complete reference list was generated; consult the Source audit sheet.",
    description: "Draft supplied-source systematic review deliverable",
  };
}

function structuredAbstract(data, copy) {
  const abstract = asObject(data.abstract);
  const fields = [
    [copy.abstractLabels[0], abstract.background],
    [copy.abstractLabels[1], abstract.objective],
    [copy.abstractLabels[2], abstract.methods],
    [copy.abstractLabels[3], abstract.results],
    [copy.abstractLabels[4], abstract.conclusions],
  ];
  return fields.map(([label, value]) => new Paragraph({
    spacing: { after: 100 },
    children: [new TextRun({ text: `${label}: `, bold: true }), new TextRun(stringValue(value) || copy.missingAbstract)],
  }));
}

async function createWorkbook(data, manifest, outputPath) {
  const workbook = new ExcelJS.Workbook();
  workbook.creator = "RagBio Review Engine";
  workbook.created = new Date();
  workbook.modified = new Date();

  const audit = reconcileAudit(data, manifest);
  const characteristics = normalizeRows(data.studyCharacteristics);
  const decisions = normalizeRows(data.decisions);
  const analysisRows = normalizeRows(data.analysisRows);
  const distantRows = normalizeRows(data.distantRows);
  const otherData = normalizeRows(data.otherData);
  const riskOfBias = normalizeRows(data.riskOfBias);
  const synthesis = normalizeRows(data.synthesis);
  const grade = normalizeRows(data.grade);
  const pico = asObject(data.pico);

  addSheet(workbook, "README", [
    { header: "Field", key: "field", width: 32 },
    { header: "Value", key: "value", width: 80 },
  ], [
    { field: "Topic", value: data.topic || manifest.query || "Not specified" },
    { field: "Research question", value: data.researchQuestion || manifest.query || "Not specified" },
    { field: "Population", value: pico.population || "Not specified" },
    { field: "Intervention / exposure", value: pico.interventionExposure || "Not specified" },
    { field: "Comparator", value: pico.comparator || "Not specified" },
    { field: "Outcomes", value: pico.outcomes || "Not specified" },
    { field: "Evidence boundary", value: "Only user-selected URLs in the immutable RagBio manifest were assessed." },
    { field: "Additional literature search", value: "No" },
    { field: "Generated", value: new Date().toISOString() },
    { field: "Publication status", value: "Draft requiring expert verification before publication" },
    { field: "Core limitation", value: "This is a supplied-source review, not a documented comprehensive multi-database systematic search." },
  ]);

  addSheet(workbook, "Study characteristics", genericColumns(characteristics, ["recordID", "studyID", "title", "year", "journal", "typeOfSource", "design", "population", "sampleSize", "interventionExposure", "comparator", "outcomes", "followUp", "overlapGroup", "extractionConfidence"]), characteristics, "No included primary-study characteristics were extractable.");
  addSheet(workbook, "Inclusion-exclusion criteria", genericColumns(decisions, ["recordID", "studyID", "title", "design", "disposition", "poolingEligibility", "reason", "dataUse", "overlapHandling", "sourceStatus", "url", "doi"]), decisions, "No eligibility decisions were supplied.");
  addSheet(workbook, "Total", [
    { header: "Category", key: "category", width: 32 },
    { header: "Count", key: "count", width: 14 },
  ], decisionCounts(decisions, audit));
  addSheet(workbook, "R", genericColumns(analysisRows, ["studyID", "recordID", "outcomeFamily", "outcomeDefinition", "arm", "events", "n", "effectMeasure", "effectValue", "ciLow", "ciHigh", "followUp", "includeInPool", "poolSet", "overlapGroup", "sourceNote", "doi"]), analysisRows, "No quantitatively poolable outcome rows were extracted.");
  addSheet(workbook, "R, Distant Recurrence", genericColumns(distantRows, ["studyID", "recordID", "outcomeDefinition", "events", "n", "effectMeasure", "effectValue", "followUp", "includeInPool", "poolSet", "sourceNote", "doi"]), distantRows, "Distant recurrence was not applicable or not extractable from the supplied sources.");
  addSheet(workbook, "Other Data", genericColumns(otherData, ["studyID", "recordID", "dataType", "outcome", "value", "unit", "timepoint", "group", "notes", "doi"]), otherData, "No additional reusable qualitative or quantitative data were extracted.");
  addSheet(workbook, "Risk of bias", genericColumns(riskOfBias, ["studyID", "recordID", "tool", "domain", "judgment", "rationale", "overallRating", "actionBeforePublication"]), riskOfBias, "Risk of bias was not assessable from the available source evidence.");
  addSheet(workbook, "Preliminary synthesis", genericColumns(synthesis, ["section", "finding", "evidenceBase", "extractionNote"]), synthesis, "No defensible synthesis was generated from the available source evidence.");
  addSheet(workbook, "GRADE", genericColumns(grade, ["outcome", "studyCount", "participants", "design", "riskOfBias", "inconsistency", "indirectness", "imprecision", "publicationBias", "certainty", "explanation"]), grade, "GRADE certainty was not assessable from the available evidence.");
  addSheet(workbook, "Codebook", [
    { header: "Field", key: "field", width: 30 },
    { header: "Definition", key: "definition", width: 90 },
  ], definitions.map(([field, definition]) => ({ field, definition })));
  addSheet(workbook, "Source audit", [
    { header: "Record ID", key: "recordID", width: 20 },
    { header: "Source type", key: "sourceType", width: 18 },
    { header: "Type of source", key: "typeOfSource", width: 22 },
    { header: "Title", key: "title", width: 45 },
    { header: "Year", key: "year", width: 10 },
    { header: "Journal", key: "journal", width: 28 },
    { header: "URL", key: "url", width: 45 },
    { header: "DOI", key: "doi", width: 24 },
    { header: "Status", key: "status", width: 18 },
    { header: "Notes", key: "notes", width: 45 },
    { header: "Confidence", key: "confidence", width: 18 },
    { header: "Manifest order", key: "manifestOrder", width: 14 },
  ], audit);

  if (workbook.worksheets.map((sheet) => sheet.name).join("|") !== requiredSheets.join("|")) {
    throw new Error("Workbook sheet contract was not satisfied");
  }
  await workbook.xlsx.writeFile(outputPath);
}

async function createManuscript(data, manifest, outputPath) {
  const copy = manuscriptCopy(manifest);
  const manuscript = asObject(data.manuscript);
  const references = normalizeRows(data.references);
  const readiness = normalizeRows(data.readiness);
  const title = stringValue(data.topic || data.title || manifest.query || copy.titleFallback);
  const children = [
    new Paragraph({
      style: "ReviewTitle",
      children: [new TextRun({ text: title, bold: true, color: "17365D", font: "Aptos Display", size: 40 })],
      alignment: AlignmentType.CENTER,
      spacing: { after: 240 },
    }),
    paragraph(copy.draftNotice, { alignment: AlignmentType.CENTER, spacing: { after: 300 } }),
    heading(copy.headings.abstract),
    ...structuredAbstract(data, copy),
    heading(copy.headings.introduction),
    ...proseParagraphs(manuscript.introduction, copy.introductionFallback),
    heading(copy.headings.methods),
    paragraph(copy.evidenceBoundary, { spacing: { after: 180 } }),
    ...proseParagraphs(manuscript.methods, copy.methodsFallback),
    heading(copy.headings.results),
    ...proseParagraphs(manuscript.results, copy.resultsFallback),
    heading(copy.headings.discussion),
    ...proseParagraphs(manuscript.discussion, copy.discussionFallback),
    heading(copy.headings.limitations, HeadingLevel.HEADING_2),
    ...proseParagraphs(manuscript.limitations, copy.limitationsFallback),
    heading(copy.headings.conclusion),
    ...proseParagraphs(manuscript.conclusion, copy.conclusionFallback),
    heading(copy.headings.dataAvailability),
    paragraph(manuscript.dataAvailability || copy.dataAvailabilityFallback),
    heading(copy.headings.references),
  ];

  if (references.length === 0) {
    children.push(paragraph(copy.missingReferences));
  } else {
    references.forEach((reference, index) => children.push(paragraph(`${index + 1}. ${first(reference, ["citation", "title"], "Unspecified reference")} ${first(reference, ["doi", "url"])}`)));
  }
  children.push(heading(copy.headings.readiness));
  const requiredReadiness = [
    "Clear PICO", "Registered protocol", "Comprehensive multi-database search", "Clear eligibility criteria",
    "Dual independent screening", "PRISMA flow diagram", "Risk-of-bias assessment", "Appropriate meta-analysis",
    "Heterogeneity analysis", "Publication-bias analysis", "GRADE certainty", "Limitations",
  ];
  const readinessByItem = new Map(readiness.map((row) => [stringValue(first(row, ["item", "criterion"])).toLowerCase(), row]));
  for (const item of requiredReadiness) {
    const row = readinessByItem.get(item.toLowerCase()) ?? {};
    const conservativeDefault = ["Registered protocol", "Comprehensive multi-database search", "Dual independent screening", "PRISMA flow diagram"].includes(item) ? "No" : "Not assessable";
    children.push(new Paragraph({
      bullet: { level: 0 },
      children: [
        new TextRun({ text: `${item}: `, bold: true }),
        new TextRun(`${first(row, ["status", "value"], conservativeDefault)}${first(row, ["note", "notes"]) ? ` — ${first(row, ["note", "notes"])}` : ""}`),
      ],
    }));
  }

  const document = new Document({
    creator: "RagBio Review Engine",
    title,
    description: copy.description,
    styles: {
      default: { document: { run: { font: "Aptos", size: 22 }, paragraph: { spacing: { line: 276 } } } },
      paragraphStyles: [{
        id: "ReviewTitle",
        name: "Review Title",
        basedOn: "Normal",
        next: "Normal",
        quickFormat: true,
        run: { font: "Aptos Display", size: 40, bold: true, color: "17365D" },
        paragraph: { spacing: { before: 0, after: 240 }, keepNext: true },
      }],
    },
    sections: [{
      properties: {
        page: {
          margin: {
            top: convertInchesToTwip(0.8),
            right: convertInchesToTwip(0.9),
            bottom: convertInchesToTwip(0.8),
            left: convertInchesToTwip(0.9),
          },
        },
      },
      children,
    }],
  });
  await writeFile(outputPath, await Packer.toBuffer(document));
}

export async function buildArtifacts(dataPath, manifestPath, outputDirectory) {
  const directory = resolve(outputDirectory);
  await mkdir(directory, { recursive: true });
  const data = JSON.parse(await readFile(resolve(dataPath), "utf8"));
  const manifest = JSON.parse(await readFile(resolve(manifestPath), "utf8"));
  const workbookPath = resolve(directory, workbookName);
  const manuscriptPath = resolve(directory, manuscriptName);
  await createWorkbook(asObject(data), asObject(manifest), workbookPath);
  await createManuscript(asObject(data), asObject(manifest), manuscriptPath);
  return { workbookPath, manuscriptPath };
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  if (process.argv.length !== 5) {
    process.stderr.write("Usage: build_artifacts.mjs review-data.json review-manifest.json output-directory\n");
    process.exitCode = 2;
  } else {
    const artifacts = await buildArtifacts(process.argv[2], process.argv[3], process.argv[4]);
    process.stdout.write(`${JSON.stringify(artifacts)}\n`);
  }
}
