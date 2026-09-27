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
