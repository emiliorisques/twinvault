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

The initial follow-up plan before diarization or cross-channel fusion was to:

1. split audio into bounded, overlapping VAD chunks;
2. detect and reject unexplained timestamp gaps;
3. retry failed or suspicious chunks independently;
4. benchmark language changes using human-verified ES/CA/EN fixtures;
5. retain each raw provider output and configuration with the report.

The opt-in `LocalTranscriptionBenchmarkTests` harness is skipped during normal tests unless explicit private-fixture environment variables are provided.

## 2026-09-27 — short ES/CA/EN code-switching fixture

A 13-second microphone fixture contains three short utterances separated by pauses. The exact spoken reference still needs to be written and human-verified, so this run is a qualitative coverage check rather than a WER measurement.

With whole-file decoding, WhisperKit retained only Catalan/Spanish-like hypotheses and omitted the English turn. The shared energy detector initially split the short English phrase into two sub-second regions; joining internal pauses up to 500 ms produced four turns and recovered output for all three language regions. The warm WhisperKit run took 9.9 seconds and returned recognizable Catalan and Spanish plus an inaccurate but present English hypothesis. Apple Speech took 5.2 seconds with the same four turns, preserved some English sounds but labelled the selected hypothesis as Spanish, and mixed Catalan into Spanish because the Catalan system asset was unavailable.

Conclusion: pause-based turns materially improve short code-switch coverage and are accepted as pipeline infrastructure, but they do not meet the accuracy release gate. WhisperKit remains the stronger multilingual candidate on this fixture; English wording and Apple model availability remain unresolved. The next fair comparison requires the exact three spoken sentences and several human-verified repetitions with different pause lengths and speakers.

### Long-form speech-turn regression

The same pause-based implementation was then rerun on the 1,299.7-second Radioteca fixture using the original reference and normalization procedure.

| Provider | Strategy | Runtime | Segments | Approx. WER |
|---|---|---:|---:|---:|
| Apple Speech | whole file | 29.1 s | 4 | 63.8% |
| Apple Speech | 253 speech turns | 68.9 s | 250 | 60.9% |
| WhisperKit large-v3 turbo | whole file | 140.3 s | 440 | 21.8% |
| WhisperKit large-v3 turbo | 253 speech turns | 275.0 s | 371 | 36.4% |

Apple gained timestamp granularity but only 2.9 absolute WER points, remained unusable for this mostly Catalan fixture, and took more than twice as long. Its Catalan `SpeechTranscriber` asset was unavailable on the tested system. WhisperKit's per-turn decoding lost too much linguistic context: WER regressed by 14.6 points and runtime nearly doubled. Applying every acoustic turn as an independent decode is therefore rejected for long-form Whisper transcription. The detector remains useful infrastructure for targeted recovery and short code-switch experiments, but the product should restore whole-file incremental Whisper decoding as the long-form baseline before further accuracy work.

### Gap-recovery experiments

Three follow-up strategies were measured on the same private fixture. Fixed overlapping windows regressed approximate WER to 28.7%; longer windows with VAD regressed it to 28.2%. Both were rejected and removed from the product. A bounded retry of only long, acoustically active gaps preserved the stronger incremental configuration and, in one run, recovered part of the 00:45–01:30 omission with approximate WER of 21.2%. A repeated run demonstrated model nondeterminism and did not recover that interval, so gap recovery is not considered a completeness guarantee.

The accepted safeguard retries a gap at most once and persists any remaining interval for review. The release gate remains unmet: this fixture is not fully human-corrected, code-switched English is not consistently preserved, and the best directional WER is still roughly 21%. No transcript-derived item may become a confirmed Twin fact automatically.

Target quality gates for the future memory pipeline are: no unexplained missing speech, human-corrected multilingual WER at or below 10% on representative fixtures, at least 95% accuracy for names/numbers/dates/commitments or explicit uncertainty flags, reliable timestamps, and mandatory provenance plus user confirmation for consequential memories.
