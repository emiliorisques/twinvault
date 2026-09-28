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

## 2026-09-28 — NVIDIA Parakeet TDT 0.6B v3 feasibility

Parakeet v3 was evaluated outside the application with FluidAudio 0.17.4 and its Core ML conversion. This kept the experiment from adding a product dependency before the provider met the quality gate. The model bundle occupied about 469 MB. The same 1,299.7-second Radioteca microphone recording and the same truncated reference and normalizer used above were processed twice. Private audio, reference text, word timestamps, and raw hypotheses remain outside the repository.

| Provider | Warm runtime | RTFx | Hypothesis words | Word edits | Approx. WER |
|---|---:|---:|---:|---:|---:|
| WhisperKit large-v3 turbo 626 MB | 140.3 s | 9.3x | 3,164 | 678 | 21.8% |
| Parakeet TDT 0.6B v3 Core ML | 15.3 s | 84.7x | 1,096 | 2,910 | 93.8% |

Parakeet was about 9.1 times faster than WhisperKit on this Mac and produced identical text on its cold and warm inference runs. Its reported aggregate confidence was 0.677. The accuracy result is nevertheless a decisive failure on this fixture: the recording is mostly Catalan, which Parakeet v3 does not support, and the model emitted a mixture of Spanish- and English-looking substitutions while omitting much of the speech. This is a deliberately adverse coverage test, not a fair estimate of Parakeet accuracy for supported Spanish or English.

Two short code-switching recordings provided a qualitative check. Parakeet retained the Spanish and English regions clearly and processed each in under 0.1 seconds of reported inference time. Catalan regions were converted into plausible-looking but incorrect Spanish-like words. Aggregate confidence remained high (0.877 and 0.936), demonstrating that provider confidence cannot safely identify unsupported Catalan.

Conclusion: Parakeet must not replace WhisperKit as the sole provider while Catalan remains a product requirement. Its speed justifies a second benchmark on a long, human-corrected Spanish/English meeting. Until that fixture exists, neither a Parakeet product dependency nor automatic Parakeet-to-Whisper routing is justified. Any future hybrid must use an independent acoustic language detector or explicit meeting-language policy; Parakeet confidence alone is insufficient.

## 2026-09-28 — Bangor Miami Spanish/English code-switching

The public `zeledon4` recording from the Bangor Miami corpus `mixed` subset was used as a supported-language stress test. It is a 1,308.9-second spontaneous conversation containing approximately 42.6% Spanish words and frequent Spanish/English switches. The dataset remained in a temporary directory and was not added to the product or repository.

All engines received the same stereo MP3. Parakeet v3 and WhisperKit used whole-file decoding without a language hint. Apple Speech used TwinVault's current shared speech-turn pipeline and evaluated its locally available language models per turn. Before scoring, case and punctuation were removed, partial-word parentheses were joined, and the corpus's `xxx`, laughter, cough, and pause markers were excluded. The score remains directional: the reference contains conversational transcription conventions and simultaneous speakers rather than a release-quality, time-aligned ASR reference.

| Provider | Runtime | RTFx | Reference words | Hypothesis words | Word edits | Approx. WER |
|---|---:|---:|---:|---:|---:|---:|
| NVIDIA Parakeet TDT 0.6B v3 Core ML | 10.3 s | 127.2x | 4,114 | 3,002 | 1,716 | 41.7% |
| WhisperKit large-v3 turbo 626 MB | 170.6 s | 7.7x | 4,114 | 3,298 | 1,696 | 41.2% |
| Apple Speech | 72.6 s | 18.0x | 4,114 | 1,629 | 2,906 | 70.6% |

Parakeet and WhisperKit were effectively tied on this noisy corpus reference: WhisperKit's 0.5-point WER advantage is not meaningful enough to offset Parakeet's 16.6-times lower runtime. Parakeet visibly retained Spanish and English within the same passage. WhisperKit translated some Spanish passages into English despite being configured for transcription, which is unacceptable for evidence fidelity even when the semantic content is similar. Apple omitted substantially more speech and remained unsuitable as the primary mixed-language engine; it also reported the unrelated Catalan asset as unavailable because the application currently enables ES, CA, and EN for every meeting.

This single recording does not meet the product's decision threshold. It does justify advancing Parakeet to a limited provider integration and a larger evaluation set, while retaining WhisperKit as the Catalan-capable fallback. The next decision gate should use at least five human-verified meeting-style fixtures, include clean and noisy audio, and score code-switch boundaries plus names, numbers, dates, and commitments separately from aggregate WER.
