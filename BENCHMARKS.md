# Local transcription benchmarks

Private fixtures and raw provider outputs are never committed. This document stores only aggregate measurements and engineering conclusions.

## 2026-09-27 — mixed Catalan/Spanish/English broadcast

Input was a 1,299.7-second microphone recording on Apple Silicon. Both providers received the exact same local M4A. The available reference transcript was truncated to its turn ending at 21:22, normalized to lowercase words with punctuation removed, and compared with Levenshtein word distance. Its text was not fully human-verified, so WER is directional rather than a release-quality accuracy claim.

| Provider | Runtime | Segments | Reference words | Hypothesis words | Word edits | Approx. WER |
|---|---:|---:|---:|---:|---:|---:|
| Apple Speech | 29.1 s | 4 | 3,104 | 3,179 | 1,980 | 63.8% |
| WhisperKit large-v3 turbo 626 MB, warm | 140.3 s | 440 | 3,104 | 3,164 | 678 | 21.8% |

The first WhisperKit run, including model download and Core ML preparation, took 265.3 seconds. Its warm run processed the recording about 9.3 times faster than real time. Apple was faster but its Catalan asset was unavailable, its four very large segments were unsuitable for precise evidence links, and the mixed-language text was heavily corrupted.

WhisperKit reduced normalized word edits by about 66% and produced useful timestamps. It is the stronger primary candidate, not yet a production decision. One warm run omitted a substantial interval around 00:45–01:30, and passages audible as English were rendered semantically in Catalan or Spanish rather than preserved verbatim. The supplied reference also contains suspected automatic translations and transcription errors, so a human-corrected reference is still required.

Before diarization or cross-channel fusion, the next accuracy increment should:

1. split audio into bounded, overlapping VAD chunks;
2. detect and reject unexplained timestamp gaps;
3. retry failed or suspicious chunks independently;
4. benchmark language changes using human-verified ES/CA/EN fixtures;
5. retain each raw provider output and configuration with the report.

The opt-in `LocalTranscriptionBenchmarkTests` harness is skipped during normal tests unless explicit private-fixture environment variables are provided.

### Gap-recovery experiments

Three follow-up strategies were measured on the same private fixture. Fixed overlapping windows regressed approximate WER to 28.7%; longer windows with VAD regressed it to 28.2%. Both were rejected and removed from the product. A bounded retry of only long, acoustically active gaps preserved the stronger incremental configuration and, in one run, recovered part of the 00:45–01:30 omission with approximate WER of 21.2%. A repeated run demonstrated model nondeterminism and did not recover that interval, so gap recovery is not considered a completeness guarantee.

The accepted safeguard retries a gap at most once and persists any remaining interval for review. The release gate remains unmet: this fixture is not fully human-corrected, code-switched English is not consistently preserved, and the best directional WER is still roughly 21%. No transcript-derived item may become a confirmed Twin fact automatically.

Target quality gates for the future memory pipeline are: no unexplained missing speech, human-corrected multilingual WER at or below 10% on representative fixtures, at least 95% accuracy for names/numbers/dates/commitments or explicit uncertainty flags, reliable timestamps, and mandatory provenance plus user confirmation for consequential memories.
