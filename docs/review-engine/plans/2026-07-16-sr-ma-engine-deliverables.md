# RagBio SR/MA Engine and Deliverables Implementation Plan

## Goal

Replace the foundation's deterministic fixture engine with the versioned workflow derived from `sr-ma-from-paper-urls`, while preserving the proven manifest, job, checkpoint, adapter, and workspace boundaries.

## Inputs and workflow assets

- Bundle the workflow instructions, schemas, references, templates, and verification scripts as versioned app resources.
- Pass only the immutable manifest and job working directory to the engine.
- Keep source access status separate from publication type, study-level eligibility, and endpoint-level pooling eligibility.
- Never infer undocumented PRISMA process details or fabricate unavailable data.

## Implementation sequence

### 1. Production helper protocol

Extend the RagBio JSONL protocol with `review.start`, `review.resume`, `review.pause`, `review.cancel`, paper progress, stage checkpoints, warnings, blocks, and deliverable events. Keep raw Codex/App Server events private to the adapter.

### 2. Source audit and retrieval

Resolve every manifest URL, record redirects and access outcomes, capture authoritative metadata, detect duplicate and companion reports, and persist source artifacts before extraction. Pause only if no source permits meaningful progress.

### 3. Classification and extraction

Implement publication/study-type classification, study-family reconciliation, structured extraction, risk-of-bias selection, and endpoint-specific eligibility. Persist typed per-paper extraction records atomically so resume starts at the next incomplete unit.

### 4. Synthesis decisions

Separate study inclusion from quantitative pooling. Pool only clinically and statistically compatible estimands. Record reasons when meta-analysis is not appropriate. Add domain-appropriate risk-of-bias and GRADE outputs.

### 5. Workbook and manuscript

Generate and validate the extraction workbook before manuscript prose. Produce an English systematic-review manuscript with claims traceable to workbook/source identifiers. Preserve the skill's verified workbook sheets, formulas, readiness checks, and manuscript sections.

### 6. Deliverable verification

Validate workbook schemas and formulas, reconcile counts against the manifest, render representative sheets, render the DOCX to pages, and inspect for clipping, overlap, broken tables, and pagination failures before completing the job.

### 7. Recovery and acceptance

Test expired login, exhausted allowance, transient network/source failures, output-only retries, process restart, app restart, and clean-Mac first login. Complete Developer ID signing, notarization, third-party notices, runtime dependency remediation, and clean-machine installation testing.

## Exit criteria

- Workbook and manuscript reconcile exactly with the immutable manifest and source audit.
- Every included or excluded study has an explicit typed reason and source trail.
- No analysis pools incompatible endpoints or unsupported estimates.
- Resume does not intentionally repeat completed paper-level extraction.
- Files pass structural, formula, count-reconciliation, and visual verification.
- A signed and notarized build completes a real review using a fresh ChatGPT login without a RagBio-owned API key.
