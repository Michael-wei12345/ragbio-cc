# RagBio Built-in SR/MA Workflow v1

Turn the immutable `review-manifest.json` into a structured `review-data.json` that RagBio can convert into two publication-style artifacts:

1. `RagBio Review Engine.xlsx`
2. `RagBio Review Engine.docx`

Use only manifest papers whose disposition is `included`. Do not search for or add other literature.

## Non-negotiable rules

- Never fabricate protocol registration, a comprehensive multi-database search, deduplication, dual independent screening, PRISMA database flow, unavailable outcome data, risk-of-bias facts, GRADE facts, or publication-bias analysis.
- Treat undocumented process items as `No`, `Partial`, or `Not assessable` and discuss them as limitations.
- Build the workbook before writing manuscript prose.
- Keep `Source type` (access status) separate from `Type of source` (publication/study design).
- Keep study disposition separate from endpoint-level pooling eligibility.
- Do not pool clinically different endpoint families merely because event counts exist.
- Prefer the latest or most complete report for an overlapping cohort and preserve companion reports as supplementary when they add a unique endpoint.

## Required workflow

1. Build one-row-per-record Source audit with URL, DOI, title, year, journal, access status, publication design, status, notes, and confidence.
2. Classify primary, background-only, supplementary, duplicate, superseded, protocol, and inaccessible sources using `references/source_type_taxonomy.md`.
3. Extract typed study characteristics and outcome data into the workbook structure in `references/workflow.md`.
4. Record `Include`, `Supplementary`, or `Exclude` for each record with an explicit reason.
5. Define each estimand before deciding whether pooling is appropriate.
6. Use RoB 2, ROBINS-I, QUADAS-2, PROBAST, or the domain-appropriate tool. Do not invent judgments unsupported by the source.
7. Add preliminary GRADE rows for key outcomes.
8. Write the English manuscript fields only after extracted counts reconcile with the manifest and study dispositions.
9. Validate `review-data.json` as strict JSON. RagBio builds and validates the Office files deterministically after the agent turn.

## review-data.json contract

Write one JSON object with these top-level keys. Arrays must be present even when empty. Do not place Markdown in the file.

- `topic`: concise review title.
- `researchQuestion`: the question actually addressed by the supplied sources.
- `pico`: object with `population`, `interventionExposure`, `comparator`, and `outcomes`.
- `abstract`: object with `background`, `objective`, `methods`, `results`, and `conclusions`.
- `studyCharacteristics`: one object per assessed report/study.
- `decisions`: one object per manifest record with `recordID`, `studyID`, `title`, `design`, `disposition`, `poolingEligibility`, `reason`, `dataUse`, `overlapHandling`, `sourceStatus`, `url`, and `doi`.
- `sourceAudit`: one object per manifest record with `recordID`, `sourceType`, `typeOfSource`, `title`, `year`, `journal`, `url`, `doi`, `status`, `notes`, and `confidence`.
- `analysisRows`, `distantRows`, `otherData`, `riskOfBias`, `synthesis`, and `grade`: typed workbook rows described in `references/workflow.md`.
- `readiness`: objects with `item`, `status`, and `note` using only Yes, No, Partial, Not assessable, or Not applicable.
- `references`: objects with `id`, `citation`, `url`, and `doi`.
- `manuscript`: object containing arrays of prose paragraphs for `introduction`, `methods`, `results`, `discussion`, `conclusion`, and `limitations`, plus string `dataAvailability`.

Use JSON numbers for numeric observations. Use empty strings, empty arrays, or explicit `Not assessable` text when evidence is unavailable; never invent a value merely to fill a field.

## Manuscript sections

Title; structured Abstract; Introduction; Methods; Results; Discussion; Conclusion; References; Appendix. Methods must state that the evidence set came from user-selected RagBio URLs and that no additional literature search was performed. Include PICO, eligibility, extraction, risk of bias, synthesis, heterogeneity, publication-bias status, GRADE, limitations, data availability, and a readiness checklist.
