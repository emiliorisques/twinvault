# Local transcription benchmarks

Private fixtures and raw provider outputs are never committed. This document stores only aggregate measurements and engineering conclusions.

## 2026-10-02 — NEO minority-Catalan regional routing

The 65-minute local microphone fixture `NEO` was used to validate the Phase 2T
decision path after its original nearly four-hour capture was safely shortened.
It has no word-for-word human reference, so this is a routing, latency, and
coverage diagnostic rather than a WER result. Raw hypotheses remain private and
outside the repository.

Acoustic identification found 165 Spanish windows with 99.1% mean confidence,
seven short Catalan candidates, four low-confidence English candidates, and one
low-confidence Portuguese candidate. The previous all-or-nothing policy sent the
entire recording to WhisperKit. The new policy treated Catalan as minority
evidence, retained a whole-recording Parakeet baseline, and invoked WhisperKit
only on contextual Catalan regions.

| Strategy | Runtime | Output segments | Output words |
|---|---:|---:|---:|
| Parakeet only | 61.7 s | 323 | 6,874 |
| WhisperKit whole recording | 424.5 s | 855 | 7,052 |
| Phase 2T automatic hybrid | 214.7 s | 328 | 6,882 |

The hybrid output contained 321 Parakeet segments and seven WhisperKit segments
labelled Catalan, preserving each provider as provenance. Two high-confidence
Catalan windows produced no regional transcript and remained explicit review
intervals; the Parakeet text was not deleted in those intervals. The hybrid was
roughly twice as fast as whole-recording WhisperKit on this run. Human review of
one closing Catalan passage found the regional Whisper output more plausible than
Parakeet's Spanish-like substitutions, but this is qualitative and does not meet
an accuracy release gate.

The fixture contains only microphone audio, including weak loudspeaker pickup of
remote participants. A Granola transcript captured a remote response that all
local engines largely missed. This demonstrates a capture limitation, not a
routing failure: the next representative benchmark must include TwinVault's
separate system-audio channel.

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

## 2026-09-28 — BSC Catalan/Spanish code-switching test set

The complete public [BSC Catalan/Spanish code-switching ASR test set](https://huggingface.co/datasets/BSC-LT/BSCs_Code_Switching_CA-ES_ASR_Test) was evaluated: 867 manually inspected utterances, 14,978.9 seconds (4 h 09 m), and 40,560 normalized reference words. Every utterance is Catalan-dominant and contains intra-sentential Spanish. The sources are `Corts Valencianes Anonymized` (457 files) and `Parlament Parla v3` (410 files). The dataset is CC BY-NC 4.0; neither its audio nor raw hypotheses are distributed with TwinVault, and use beyond evaluation would require a licence review.

Both engines received the same local FLAC files and no language hint. Text was normalized with Unicode NFKC, lowercase conversion, punctuation removal, and whitespace collapse before calculating corpus-level Levenshtein word error rate. The temporary batch runner loaded each model once. Five WhisperKit jobs initially timed out when eight Core ML predictions ran concurrently; all five succeeded when retried serially, confirming a benchmark concurrency problem rather than unreadable audio.

| Provider | Runtime | RTFx | Hypothesis words | Word edits | Corpus WER | Empty outputs |
|---|---:|---:|---:|---:|---:|---:|
| NVIDIA Parakeet TDT 0.6B v3 Core ML | 158.8 s | 94.3x | 28,671 | 29,803 | 73.5% | 37 |
| WhisperKit large-v3 turbo 626 MB | 1,465.2 s | 10.2x | 38,950 | 13,615 | 33.6% | 23 |

| Subset | Parakeet WER | WhisperKit WER |
|---|---:|---:|
| Corts Valencianes Anonymized | 63.2% | 45.9% |
| Parlament Parla v3 | 85.6% | 19.0% |

WhisperKit had the lower per-file WER on 678 recordings, Parakeet on 132, with 57 ties. Its median per-file advantage was 33.3 WER points. Parakeet's 9.2-times runtime advantage is irrelevant here because it does not support Catalan and failed badly, especially on the cleaner `Parlament Parla v3` subset. Its confidence must not be used to route Catalan audio.

The large source difference matters. `Corts Valencianes Anonymized` intentionally alters voices and is an adverse robustness test; `Parlament Parla v3` is closer to normal audible speech. The related [Interspeech 2025 study](https://arxiv.org/abs/2507.13875) reports 20.96% WER for its base Whisper model on the code-switching portion of Parlament Parla and 35.43% on Corts, while a code-switching fine-tune improves those figures. Its scoring slice and model execution are not identical to this benchmark, so those numbers are context rather than a direct reproduction. TwinVault's 19.0% WhisperKit result on the full Parlament Parla subset is therefore plausible, but it still misses the product's 10% representative-fixture release gate.

Conclusion: for Catalan/Spanish meetings, WhisperKit remains the only viable current provider of the two. Parakeet can still be considered for an explicitly selected Spanish/English mode, but it must never be the automatic default when Catalan may occur. The next accuracy experiment should compare the existing WhisperKit model with BSC's Catalan/Spanish code-switching fine-tune on a small, human-verified meeting-style holdout; diarization should remain a separate downstream stage and will not repair recognition errors.

## 2026-09-28 — BSC Catalan/Spanish fine-tune feasibility

The Apache-2.0 [`BSC-LT/whisper-timestamped-cs`](https://huggingface.co/BSC-LT/whisper-timestamped-cs) model was evaluated outside the application before considering a product dependency. It is a 2B-parameter Whisper large-v3 fine-tune trained on two hours of Catalan/Spanish code-switching. The downloaded BF16 weights occupied about 2.9 GB. The temporary Python/PyTorch environment and weights were not added to TwinVault.

The 1,299.7-second Radioteca microphone fixture, reference cutoff, normalizer, and corpus-level Levenshtein calculation were identical to the earlier WhisperKit run.

| Provider | Runtime | RTFx | Hypothesis words | Word edits | Approx. WER |
|---|---:|---:|---:|---:|---:|
| WhisperKit large-v3 turbo 626 MB, Core ML | 140.3 s | 9.3x | 3,164 | 678 | 21.8% |
| BSC whisper-timestamped-cs, PyTorch/MPS BF16 | 1,430.6 s | 0.91x | 3,384 | 569 | 18.3% |

The BSC fine-tune reduced word edits by 109, a 3.5-point absolute and 16.1% relative WER improvement. This is a real but insufficient gain for the product's 10% release gate. Runtime is not a direct Core ML forecast, but the unconverted model was 10.2 times slower than the existing compressed WhisperKit model and substantially larger.

The required three-language fixture was decisive. Given the short ES/CA/EN recording, BSC returned `Buenos días. Avui parlem de pressupost.` and omitted the entire English region. WhisperKit's wording for that region was inaccurate, but it at least retained speech from all three regions. The BSC model also translated an English passage in Radioteca into Catalan-like text rather than preserving the spoken language.

Conclusion: do not convert or integrate this BSC fine-tune as TwinVault's default. It improves a strictly CA/ES meeting, but violates the ES/CA/EN coverage requirement and does not justify a second 3 GB model yet. Keep WhisperKit as the local multilingual default. Reconsider a specialized CA/ES model only after explicit per-meeting language profiles exist and representative human-verified fixtures demonstrate that the extra operational complexity is worthwhile.

## 2026-09-29 — latest two local meetings, Fast ES/EN versus WhisperKit

The two newest private meetings were tested channel-by-channel with the same application
providers. Raw audio and hypotheses remain outside the repository. There is no manually
corrected reference for these recordings, so this is a speed and coverage diagnostic,
not an accuracy/WER benchmark.

| Recording/channel | Duration | Parakeet runtime / words | WhisperKit runtime / words |
|---|---:|---:|---:|
| `test 2` microphone | 354.6 s | 21.4 s / 884 | 134.2 s / 847 |
| `test 2` system | 354.4 s | 5.6 s / 466 | 46.9 s / 467 |
| `Test Dani` microphone | 49.0 s | 0.46 s / 127 | 13.1 s / 126 |
| `Test Dani` system | 48.7 s | 0.45 s / 81 | 7.3 s / 77 |

All eight provider/channel runs completed without an engine error. In `test 2`, the
orange coverage intervals closely match actual silence in the system track: that channel
contains about 156.6 seconds of silence (44.2%), including long silent spans around
01:06–01:28, 02:43–03:19, 04:08–04:49 and 05:13–05:24. The warning therefore means
“review this gap” and, for this recording, is not evidence that Fast ES/EN failed.

A brief unscored inspection found WhisperKit more coherent in parts of the mixed
Spanish/English conversation, while Parakeet was much faster and recovered the late
short responses in `Test Dani` that WhisperKit omitted. Neither observation is an
accuracy decision without a human reference. The system channel is the preferred source
for remote participants; the microphone channel includes the local speaker plus room
echo and should not be merged naively. Cross-channel alignment/deduplication remains a
separate future step.

## 2026-09-29 — public eight-case ES/CA/EN suite

Fast ES/EN (Parakeet) and the current TwinVault WhisperKit provider processed all eight
generated benchmark WAVs successfully. Scoring used Unicode NFKC, lowercase text,
punctuation removal and corpus-level Levenshtein word edits. References are copied from
FLEURS/AMI and have not yet received the required word-for-word human review, so all WER
figures are directional. AMI includes overlapping speech, making its linear WER an
especially conservative measure.

| Case | Languages | Fast ES/EN WER / runtime | WhisperKit WER / runtime |
|---|---|---:|---:|
| ES clean | ES | 5.8% / 1.1 s | 3.3% / 20.2 s |
| EN clean | EN | 6.9% / 1.1 s | 45.7% / 15.9 s |
| ES/EN | ES+EN | 6.5% / 1.3 s | 22.1% / 15.0 s |
| CA/ES | CA+ES | 54.9% / 2.8 s | 11.6% / 21.3 s |
| ES/CA/EN | ES+CA+EN | 34.4% / 1.4 s | 14.7% / 27.9 s |
| multilingual + noise | ES+CA+EN | 45.4% / 3.7 s | 26.3% / 18.6 s |
| AMI meeting overlap | EN | 22.4% / 1.9 s | 71.6% / 28.7 s |
| stress test | ES+CA+EN | 45.5% / 3.0 s | 26.5% / 23.7 s |

Across all 1,069 seconds and 2,363 reference words, Fast ES/EN obtained 27.7% directional
micro-WER in 16.3 seconds (65.5x real time); WhisperKit obtained 31.5% in 171.3 seconds
(6.2x real time). That aggregate hides the actual routing decision:

- on cases 01–03 (ES/EN, without the overlapping AMI reconstruction), Fast scored 6.4%
  and WhisperKit 23.8%;
- on the four Catalan-containing cases, Fast scored 44.5% and WhisperKit 19.4%;
- on AMI alone, Fast scored 22.4% and WhisperKit 71.6%.

The English and AMI failures must not be interpreted as a limitation of the underlying
Whisper model alone. The current product provider slices every detected acoustic turn and
decodes each independently. That strategy was already shown to regress long-form Whisper
accuracy, and here it omitted substantial English content. This benchmark reinforces the
pending engineering change: restore a whole-file/incremental Whisper baseline and rerun
the same suite before deciding final routing.

Current evidence supports Fast ES/EN for explicitly ES/EN meetings and WhisperKit when
Catalan can occur. It does not support routing from Parakeet confidence or silently using
Fast for a potentially Catalan meeting. No transcript-derived memory should be confirmed
automatically from either provider.

## 2026-09-29 — whole-recording Whisper correction

The same eight WAV files and references were rerun after removing the outer energy-turn
slicing from the WhisperKit provider. WhisperKit now receives each complete recording
once; its own incremental loader and VAD remain active. The application energy detector
is used only to flag acoustically active regions left uncovered by the final transcript.
Fast ES/EN was unchanged and its previous results were retained for comparison.

| Case | Whisper per-turn WER | Whisper whole-recording WER | Whole-recording runtime |
|---|---:|---:|---:|
| ES clean | 3.3% | 5.4% | 84.4 s |
| EN clean | 45.7% | 11.4% | 13.9 s |
| ES/EN | 22.1% | 25.4% | 20.0 s |
| CA/ES | 11.6% | 21.1% | 20.9 s |
| ES/CA/EN | 14.7% | 33.1% | 24.2 s |
| multilingual + noise | 26.3% | 26.7% | 21.4 s |
| AMI meeting overlap | 71.6% | 31.1% | 26.2 s |
| stress test | 26.5% | 29.2% | 19.7 s |

Directional micro-WER across all 1,069 seconds improved from 31.5% to 24.2%. The
largest corrections were the English-clean and AMI cases, confirming that independent
short-turn decoding was losing important Whisper context. The first run includes an
84.4-second cold model preparation cost; total measured runtime was 230.7 seconds, or
4.6x real time. Runtime should therefore be compared with both cold and warm runs in a
future performance benchmark.

The correction is not a complete multilingual routing solution. Whole-recording Whisper
regressed on several short code-switch cases, while Fast ES/EN still scored 6.4% versus
Whisper's 14.6% on the non-AMI ES/EN cases. On the four Catalan-containing cases,
Whisper remained better at 27.8% versus Fast's 44.5%. References are dataset-provided,
not yet word-for-word human verified, and AMI overlap makes linear WER conservative.
The next experiment should detect language regions acoustically and route only
high-confidence Catalan regions away from the fast ES/EN path; transcript text must not
be used as the sole router.

## 2026-09-29 — acoustic language routing feasibility

WhisperKit language identification was run over bounded energy-active windows from the
same eight public benchmark files. This stage decodes only a language token; it does not
transcribe window text and does not alter the later provider's whole-recording input.
Across 73 windows it predicted 33 Spanish, 25 English, and 15 Catalan regions.

| Case | Expected languages | Detected languages | Routing decision | LID runtime |
|---|---|---|---|---:|
| ES clean | ES | ES | Fast ES/EN | 12.5 s |
| EN clean | EN | EN | Fast ES/EN | 9.2 s |
| ES/EN | ES+EN | ES+EN | Fast ES/EN | 9.9 s |
| CA/ES | CA+ES | CA+ES | WhisperKit | 11.4 s |
| ES/CA/EN | ES+CA+EN | ES+CA+EN | WhisperKit | 14.5 s |
| multilingual + noise | ES+CA+EN | ES+CA | WhisperKit | 10.3 s |
| AMI meeting overlap | EN | EN | Fast ES/EN | 14.4 s |
| stress test | ES+CA+EN | ES+CA+EN | WhisperKit | 11.5 s |

All four Catalan-containing cases took the conservative multilingual route; all four
cases without Catalan took the fast route. Applying those decisions to the already
measured ASR outputs gives 468 word edits over 2,363 reference words, or 19.8%
directional micro-WER. This improves on whole-recording WhisperKit at 24.2% and Parakeet
at 27.7%. Language identification took 93.7 seconds in total. Combined with the selected
providers, estimated measured runtime is 185.4 seconds for 1,069 seconds of audio, about
5.8x real time. A production process can reuse the loaded WhisperKit actor, but cold and
warm energy measurements are still required.

This is enough to expose the automatic profile for user testing, not to declare it
production-ready. The references are not yet word-for-word human verified, short
isolated language switches below the analysis window minimum may be missed, and these
eight files do not cover all accents or meeting conditions. Routing therefore defaults
to WhisperKit whenever evidence is absent, weak, Catalan, or unsupported. Diarization
remains downstream and independent.

## 2026-10-01 — Nemotron 3.5 multilingual evaluation

FluidAudio 0.17.4's streaming Nemotron 3.5 0.6B Core ML adapter was run locally in
automatic-language mode over the same eight complete WAV files. The first private run
downloaded and prepared 641 MB of model assets; meeting audio was never uploaded. The
four channels from the two latest private meetings were also processed as a qualitative
comparison. Those private recordings have no human-corrected references, so their
pairwise model disagreement is not reported as accuracy.

| Case | Languages | Parakeet WER / time | WhisperKit WER / time | Nemotron WER / time |
|---|---|---:|---:|---:|
| ES clean | ES | 5.8% / 1.10 s | 5.4% / 84.38 s | 11.2% / 2.67 s |
| EN clean | EN | 6.9% / 1.10 s | 11.4% / 13.93 s | 8.2% / 2.34 s |
| ES/EN | ES+EN | 6.5% / 1.31 s | 25.4% / 20.01 s | 15.9% / 3.31 s |
| CA/ES | CA+ES | 54.9% / 2.78 s | 21.1% / 20.85 s | 44.0% / 2.77 s |
| ES/CA/EN | ES+CA+EN | 34.4% / 1.41 s | 33.1% / 24.21 s | 35.6% / 4.14 s |
| multilingual + noise | ES+CA+EN | 45.4% / 3.67 s | 26.7% / 21.39 s | 44.6% / 3.60 s |
| AMI meeting overlap | EN | 22.4% / 1.92 s | 31.1% / 26.19 s | 26.3% / 3.97 s |
| stress test | ES+CA+EN | 45.5% / 3.02 s | 29.2% / 19.74 s | 49.6% / 2.68 s |

Across ES/EN cases 01–03, Parakeet scored 6.4%, Nemotron 12.0%, and WhisperKit
14.6%. On the four Catalan-containing cases, WhisperKit scored 27.8%, Nemotron 43.0%,
and Parakeet 44.5%. Aggregate micro-WER was 24.2% for WhisperKit, 27.7% for Parakeet,
and 29.6% for Nemotron. Nemotron completed the suite in 25.5 seconds after model
availability, but speed does not compensate for the accuracy loss. Automatic Nemotron
also omitted a detected-language value on several successful private recordings.

Decision: do not register Nemotron as a product profile and do not use it for language
identification. Keep the adapter as a reproducible evaluation boundary. The current
automatic policy remains independent acoustic LID, Parakeet for confident ES/EN, and
whole-recording WhisperKit for Catalan or uncertainty.

## 2026-10-02 — Quiet brief Catalan switch regression

The private `test 2 oct` microphone fixture contains about twenty seconds of speech:
Spanish, one brief Catalan turn, then Spanish. The first automatic run analyzed only
the louder first half, classified the recording as Spanish, and used Parakeet alone.
The omitted Catalan turn measured roughly -53 dBFS mean level. A temporary +20 dB
diagnostic copy identified the isolated turn as Catalan with 90.2% confidence, proving
that the language model could classify it and that the energy gate was the failure.

After lowering the adaptive detector floor, preserving complete language turns, and
forcing Catalan only for the regional decode, the original unmodified audio identified
`00:14.35–00:16.50` as Catalan with 97.7% confidence. The final automatic run completed
in 14.5 seconds with no review intervals: Parakeet retained the Spanish evidence and
WhisperKit produced `Por ejemplo, ahora parlo un trozo en catalán.` with `ca` provenance.
The system-audio channel contained no detected speech. This is a targeted regression
result, not a WER claim; the fixture still needs a word-for-word human reference.

## 2026-10-03 — Real two-channel alignment and automatic route

The private 25-second meeting `nuevo test` was captured simultaneously through the
microphone and ScreenCaptureKit system-audio paths. Raw audio and hypotheses remain
outside the repository. The offline energy-envelope analyzer found a 0.30-second
file-relative microphone lag with 0.926 confidence from one full-recording anchor and completed in
0.40 seconds. This exceeds the 0.70 persistence threshold and was the first real fixture
to validate using acoustic alignment in the playback-leakage safety gate.

Both channels were also processed independently by the automatic ES/CA/EN route. The
system channel completed warm in 7.3 seconds and returned 61 words in eight segments;
the microphone channel's cold run took 82.2 seconds and returned 46 words in seven
segments. Both routed to Parakeet, produced no review interval, and preserved mixed
Spanish/English speech. The system transcript was visibly more complete and coherent,
especially at the end. This supports keeping system audio as the primary evidence for
remote playback while retaining microphone evidence separately. It is not a WER result:
the fixture has no human-corrected reference, is short, and provides only one alignment
anchor, so a longer two-channel meeting is still required for drift validation.

Phase 2W corrected that result for the recorders' independently measured meeting offsets:
the meeting-timeline playback delay is 0.076 seconds, while confidence remains 0.926.
Segment-level aligned envelope comparison produced six usable scores across seven short
microphone segments (one was below the 1.5-second evidence minimum). Scores ranged from
0.266 to 0.892; two exceeded the deliberately conservative 0.75 acoustic threshold, and
one of those was independently corroborated by transcript agreement. This confirms that
acoustics recover duplicates even when two ASR outputs use different words, but also that
energy envelopes alone must fail closed rather than hide every overlapping microphone
segment. The conversation view therefore suppresses only strong findings and keeps all
other evidence visible and unassigned.
