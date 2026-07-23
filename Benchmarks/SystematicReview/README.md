# RagBio systematic-review search benchmark

This benchmark measures whether RagBio retrieves articles that are useful for a
specific systematic review. It does not treat every bibliography entry in a
published review as relevant.

## Gold-standard levels

1. `goldStudyFamilies` contains the primary included trials. Multiple reports of
   the same trial are grouped under one family.
2. Reports inside a family may be primary, follow-up, subgroup, safety, protocol,
   or registry reports. Finding any report retrieves the family, while companion
   coverage can be examined separately.
3. `contextualSources` is reserved for reviews, guidelines, and methodological
   sources useful for writing but not eligible primary studies.

## Blind-run rules

- Use the review's `searchCutoff`; later publications do not affect its score.
- Do not use the target review itself as a citation-chasing seed.
- Preserve database responses for comparisons between algorithms.
- Run both the natural-language input and the structured eligibility input.
- Report results at database fusion, the 480-record pool, the 180-record AI
  screening pool, the final 5-point threshold, and ranks 20 and 50.

## Safety gates

- End-to-end recall at 480 records: at least 95%.
- Retention of source-available study families after AI screening at 180
  records: at least 95%.
- Retention of source-available study families after the visible score
  threshold: at least 95%.
- End-to-end recall after the visible score threshold: at least 95% across the
  complete benchmark.
- Critical study families hidden below the score threshold: zero.

The ten manifests cover five intervention reviews, two diagnostic reviews, two
prognostic reviews, and one etiologic/exposure review. They contain 72 included
study families or independently included reports. Identifiers were transcribed
from each review's included-study table and included-study references, not from
the complete bibliography.

The July 2026 run with `gpt-5.4-mini` produced:

- database fusion and 480-record pool: 70/72 (97.2%);
- AI screening at 180: 70/70 source-available families retained (100%);
- visible score threshold: 70/70 source-available families retained (100%);
- end-to-end threshold recall: 70/72 (97.2%);
- Recall@20: 56/72 (77.8%);
- Recall@50: 69/72 (95.8%).

The two discovery misses were older regional publications without retrievable
records in the configured OpenAlex, PubMed, or ClinicalTrials.gov sources. They
remain in the gold standard and are reported as source-coverage gaps rather
than AI-screening failures.

A live benchmark result is not reproducible until its candidate responses have
been frozen; the manifests alone are the audited gold standard. Frozen network
and model artifacts stay local and are not committed.

Live network and model tests are opt-in:

```sh
RAGBIO_RUN_DISCOVERY_BENCHMARK=1 swift test --filter liveTenReviewBenchmarkMeasuresBlindMultiSourceRecallBeforeAITriage
RAGBIO_RUN_AI_BENCHMARK=1 swift test --filter liveTenReviewBenchmarkMeasuresAIRecallAt180UsingFrozenCandidates
RAGBIO_RUN_GLOBAL_BENCHMARK=1 swift test --filter liveTenReviewBenchmarkMeasuresFinalGlobalRanking
RAGBIO_REPLAY_GLOBAL_BENCHMARK=1 swift test --filter replayFrozenFinalDiagnosticsThroughCurrentSafetyRules
```

Set `RAGBIO_SR_BENCHMARK_REVIEW_ID` to one manifest ID to rerun a single review.
The cache directory is intentionally ignored. Gold manifests and evaluator
tests are versioned; downloaded candidates, model outputs, and diagnostics are
local experiment artifacts.
