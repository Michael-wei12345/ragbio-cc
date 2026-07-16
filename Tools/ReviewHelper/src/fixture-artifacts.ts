import { mkdir, writeFile } from "node:fs/promises";
import { resolve } from "node:path";
import { Document, Packer, Paragraph, TextRun } from "docx";
import ExcelJS from "exceljs";

export interface FixtureArtifacts {
  workbookPath: string;
  manuscriptPath: string;
}

export async function createFixtureArtifacts(workingDirectory: string): Promise<FixtureArtifacts> {
  const directory = resolve(workingDirectory);
  await mkdir(directory, { recursive: true });

  const workbookPath = resolve(directory, "RagBio Review Probe.xlsx");
  const workbook = new ExcelJS.Workbook();
  workbook.creator = "RagBio Review Engine Probe";

  const readme = workbook.addWorksheet("README");
  readme.addRow(["RagBio Review Engine connection probe"]);
  readme.addRow(["This workbook confirms local artifact generation. It is not a review result."]);

  const audit = workbook.addWorksheet("Source audit");
  audit.addRow(["Source", "Status"]);
  audit.addRow(["fixture://ragbio-review-probe", "Verified"]);
  await workbook.xlsx.writeFile(workbookPath);

  const manuscriptPath = resolve(directory, "RagBio Review Probe.docx");
  const manuscript = new Document({
    sections: [{
      children: [
        new Paragraph({
          children: [new TextRun({ text: "RagBio Review Engine Probe", bold: true })],
          heading: "Title",
        }),
        new Paragraph("This document confirms local artifact generation. It is not a systematic review result."),
      ],
    }],
  });
  await writeFile(manuscriptPath, await Packer.toBuffer(manuscript));

  return { workbookPath, manuscriptPath };
}
