# Workbook contract

Create these sheets unless no source can support them:

1. `README`: topic, supplied-source boundary, date, status, limitations, and whether extra searching occurred.
2. `Study characteristics`: one row per report with record/study IDs, bibliographic fields, source status, type of source, design, population, sample size, intervention/exposure, comparator, outcomes, follow-up, overlap group, and extraction confidence.
3. `Inclusion-exclusion criteria`: record ID, study ID, title, design, disposition, endpoint pooling eligibility, reason/data use, overlap handling, source status, URL, DOI.
4. `Total`: included, supplementary, excluded, duplicate, inaccessible, and final analysis accounting.
5. `R`: one row per study-outcome-arm with typed numeric denominators/events/effect values, outcome family, definition, follow-up, include-in-pool, pool set, overlap group, source note, DOI.
6. `R, Distant Recurrence`: create when relevant; otherwise retain headers and explain non-applicability.
7. `Other Data`: adverse events, costs, patient-reported, qualitative, subgroup, technique, or other reusable evidence.
8. `Risk of bias`: one row per included primary study, tool, domain judgments, overall rating, rationale, action before publication.
9. `Preliminary synthesis`: section, finding, evidence base, extraction note.
10. `GRADE`: outcome, study count, participants, design, five downgrade domains, certainty, explanation.
11. `Codebook`: define every non-obvious field, event definition, inclusion flag, and analysis set.
12. `Source audit`: one row per manifest record; place `Type of source` immediately after `Source type`.

## Eligibility and synthesis

- Study disposition is `Include`, `Supplementary`, or `Exclude`.
- Pooling eligibility is a separate Yes/No/Maybe decision for each endpoint.
- Never mix residual pathology, recurrence, distant metastasis, treatment success, complications, costs, or patient-reported outcomes without a defensible shared estimand.
- For single-arm proportions, a random-effects logit model with transparent continuity correction may be used. Report k, events/n, pooled estimate, 95% CI, I2, tau2, and model.
- For comparative binary outcomes use RR or OR as appropriate; use HR for time-to-event outcomes when available; use MD/SMD for continuous outcomes.
- Do not assess publication bias with fewer than 10 comparable studies; say it was not assessable.

## Required readiness checklist

Rows: Clear PICO; Registered protocol; Comprehensive multi-database search; Clear eligibility criteria; Dual independent screening; PRISMA flow diagram; Risk-of-bias assessment; Appropriate meta-analysis; Heterogeneity analysis; Publication-bias analysis; GRADE certainty; Limitations. Values: `Yes`, `No`, `Partial`, `Not assessable`, or `Not applicable`.
