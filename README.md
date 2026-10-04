# TwinVault

TwinVault is a native, local-first macOS meeting memory application. It records meeting audio, keeps notes and important timestamps inspectable on-device, and can transcribe a selected local audio channel using replaceable on-device speech engines. It has no cloud inference, analytics, or audio upload.

## Current capabilities

- Create and record a meeting with explicit microphone permission.
- Show recording duration and state.
- Capture a simple note and important moments while recording.
- Store audio separately from versioned meeting metadata.
- Browse previous meetings and inspect notes, timestamps, and audio status.
- Transcribe a completed meeting locally with Spanish, Catalan, and English enabled by default.
- Choose an explicit transcription profile: automatic ES/CA/EN routing (recommended but still experimental), always-multilingual WhisperKit, fast ES/EN Parakeet, or Apple Speech as the system-native comparison mode.
- See model preparation, download, loading, and local transcription states; Parakeet reports real download percentage and active work can be cancelled without replacing an existing transcript.
- Detect language from local acoustic windows without using transcript text or changing the transcription boundaries.
- Keep whole-recording WhisperKit for Catalan-dominant audio, while minority Catalan uses wide contextual regions over a Parakeet ES/EN baseline.
- Anchor newly recorded microphone and system-audio files to the meeting timeline.
- Warn immediately if macOS interrupts system-audio capture while keeping the microphone active.
- Show independent live health for microphone and system audio, and retain capture failures with the meeting for later inspection.
- Mark long transcript intervals without text for human review instead of presenting the transcript as complete.
- Mark strongly aligned duplicate text across system and microphone channels as possible speaker playback leakage; microphone capture is never treated as proof of the user's identity.
- Retry acoustically confirmed gaps from the fast ES/EN route with multilingual WhisperKit and retain only gap-covering evidence.
- Supply a bounded, local vocabulary prompt from the user-entered meeting title to WhisperKit.
- Estimate post-recording microphone/system delay and clock drift from bounded local acoustic fingerprints, without assuming that microphone audio is the user's voice.
- Detect temporary speakers locally in saved system audio and show those meeting-only labels beside overlapping transcript evidence.

## Development

Requirements: Apple Silicon Mac, macOS 15+, Xcode 16+ (the current machine has Xcode 27), and an accepted Xcode license.

Open `TwinVault.xcodeproj`, select the `TwinVault` scheme, and Run. Tests are available with **Product > Test**. The package can also be checked with `swift test` when the selected Command Line Tools SDK matches the Swift compiler.

Runtime data is stored below `~/Library/Application Support/TwinVault/`:

```text
TwinVault/
├── database/meetings-v1.json
├── audio/<meeting UUID>.m4a
├── audio/<meeting UUID>-system.m4a
└── models/                       # downloaded local model assets
```

Metadata writes are atomic. Audio never leaves the device. Removing the application does not currently erase the vault; export and verified deletion workflows are future security work.

Phase 2B adds opt-in system audio capture through ScreenCaptureKit. System audio is written to a separate local M4A file; no screen output is registered and no video frames are stored. A permission or capture failure falls back to microphone-only recording. Stream interruptions are observed explicitly; the writer is finalized even when `stopCapture()` fails, finalization is serialized with sample delivery, and the completed M4A is opened for validation before it is accepted.

Meeting details provide local Play/Stop controls for each captured channel. Playback resolves only safe filenames inside the vault audio directory and never uploads media.

Phase 2C adds post-meeting transcription through `SpeechAnalyzer` and `SpeechTranscriber` on macOS 26+. The user explicitly chooses the microphone or system-audio recording to transcribe. Apple may download the selected language models once through the system-managed `AssetInventory`; recorded audio remains on-device. Timestamped segments persist with the source recording ID, provider ID, and locale.

Phase 2D enables `es-ES`, `ca-ES`, and `en-US` for every meeting by default. Apple Speech exposes one locale per transcriber, so the current adapter processes the same audio sequentially with three locale-specific transcribers and retains the strongest non-overlapping hypotheses using Apple's confidence metadata. Language assets are installed independently. A failed installation gets one clean retry after its stale reservation is released; if Apple still cannot install that model, TwinVault saves results from the available languages and tells the user which language was skipped. This is a replaceable, deliberately isolated heuristic; mixed-language accuracy and energy use must be benchmarked with consented fixtures before production use.

Phase 2E gives each new audio reference a meeting-timeline offset measured when its capture service reports that recording has started. The meeting itself now begins after microphone permission is resolved, so permission dialogs do not inflate its duration. This wall-clock service boundary is an initial alignment anchor, not sample-accurate synchronization; buffer host-time calibration is still required before automatic cross-channel deduplication.

Phase 2F adds WhisperKit 1.1.0 as a pinned Swift Package dependency and keeps it behind `SpeechToTextProvider`. The post-meeting Transcribe menu makes engine choice explicit. WhisperKit uses Argmax's recommended `large-v3-v20240930_626MB` multilingual Core ML model, incremental audio loading, and VAD chunk boundaries. The first WhisperKit transcription downloads the model into `TwinVault/models/`; later runs reuse the local assets. This download contacts the model host, but meeting audio is never uploaded. Tests inject a fake engine and neither download a model nor require private recordings.

Phase 2G adds a bounded quality safeguard. WhisperKit examines long timestamp gaps, retries an acoustically active gap at most once, and persists any remaining interval as `TranscriptReviewInterval`. The meeting detail view labels those intervals explicitly. A transcript with review intervals is incomplete evidence and must not feed future automatic facts or commitments without verification.

Phase 2H adds one shared, local speech-turn detector. It measures short PCM energy windows and joins brief internal pauses. Apple evaluates its available locale models on lossless temporary CAF slices and translates their timestamps back to the original recording timeline. Temporary slices are removed after each run and are never stored in the vault. A `SpeechTurn` is only an acoustic interval: it contains no speaker identity and is not diarization.

Phase 2I replaces raw engine selection in the UI with explicit transcription profiles. The default `Multilingual ES · CA · EN` profile routes to WhisperKit; Apple Speech remains an explicit comparison option. `TranscriptionPolicy` exposes only profiles whose provider is registered, chooses the recommended available profile deterministically, and supplies the exact requested locales to the provider. Routing is selected before transcription and is never inferred from transcript text.

Phase 2J adds FluidAudio 0.17.4 as a pinned dependency and exposes Parakeet TDT 0.6B v3 only through `Fast ES · EN — No Catalan (Experimental)`. This is a manual profile, never the default or an automatic fallback. The provider rejects any requested locale outside Spanish and English before it reads audio or invokes the engine. Its first explicit use downloads the Core ML model into `TwinVault/models/`; recordings remain local. Word timings are grouped into bounded evidence segments, provider/recording provenance is persisted, and long uncovered intervals remain marked for review. Parakeet does not return a trustworthy per-segment language label, so TwinVault stores none rather than inventing one.

Phase 2K makes long-running transcription work visible and cancellable. FluidAudio's native callback supplies Parakeet's real model-download percentage and compilation state. Apple Speech and WhisperKit expose honest coarse stages because their current integration APIs do not provide an equivalent byte-level fraction. Cancellation is cooperative: TwinVault never saves a cancelled run and preserves the previous transcript, while a model runtime may need to finish its current non-interruptible Core ML operation before returning. Downloaded model files are retained for later local use.

Phase 2L restores whole-recording decoding for WhisperKit. Splitting a multilingual recording at every energy-defined speech turn removed useful linguistic context and caused missed English speech in the benchmark. WhisperKit now receives the original recording once, keeps its native incremental loading and VAD chunking, and preserves the engine's global timestamps. The shared energy detector runs afterwards only to identify acoustically active intervals that the transcript did not cover. On the public eight-case suite this reduced directional micro-WER from 31.5% to 24.2%; mixed-language quality still requires explicit routing experiments before production use.

Phase 2M adds conservative recording-level routing. WhisperKit inspects bounded acoustically active windows and returns language observations with time ranges and confidence; transcript text is never used to choose an engine. Any Catalan, unsupported language, missing evidence, or low-confidence result routes the complete recording to WhisperKit. Only consistently confident Spanish/English evidence routes the complete recording to Parakeet. The two engines still transcribe whole recordings, and diarization remains a separate future stage. On the eight-case suite the detector routed all cases as expected and the resulting hybrid selection reduced directional micro-WER to 19.8%. The profile is visible as experimental because the fixture references still require human verification.

Phase 2N evaluates NVIDIA Nemotron 3.5 through FluidAudio without registering it as a product profile. The adapter is local, replaceable, provenance-preserving, and covered by deterministic tests, but remains an evaluation tool because the converted model's distribution terms require a separate shipping review. On the same eight-case suite Nemotron scored 12.0% WER on the ES/EN slice, 43.0% when Catalan was present, and 29.6% overall. It was fast after model preparation, but did not beat Parakeet for ES/EN or WhisperKit for Catalan and did not return reliable language labels for every recording. The automatic product policy is therefore unchanged.

Phase 2O adds a conservative cross-channel attribution guard. Once both microphone and system channels have transcripts, TwinVault compares only segments that can be placed on the same meeting timeline. Strong ordered-word similarity plus strong temporal overlap produces a persisted `possiblePlaybackLeakage` finding linked to the microphone segment and every matching system segment. The UI exposes the warning, but no transcript is deleted or assigned to a person. A microphone segment without such a finding still requires separate speaker-identification evidence; capture channel is never identity. This transcript-level safeguard is not acoustic echo cancellation and must later be complemented by sample-timestamp calibration and acoustic correlation.

Phase 2P adds bounded quality recovery to the automatic route. Parakeet now reports only long gaps that overlap acoustically detected speech rather than treating ordinary silence as missing transcription. If such gaps remain, the router performs one multilingual WhisperKit pass and retains only segments whose midpoint falls inside the flagged intervals; every retained segment preserves its actual provider ID. Failure of the repair pass leaves the fast transcript and its review warnings intact. WhisperKit also receives a sanitized, deduplicated prompt containing at most twelve explicit contextual terms; this increment supplies only the user-entered meeting title. The prompt may guide decoding but never performs post-hoc text replacement. Parakeet vocabulary boosting remains disabled because its current FluidAudio path requires an additional CTC model and a different timing pipeline that has not been benchmarked.

Phase 2Q hardens the future diarization/identity boundary without installing a diarization model. Every `DiarizationTurn` can retain its exact source recording and replaceable provider while exposing only a session-local speaker label. `SpeakerIdentityMatch` records whether a proposal came from model inference, a future opt-in local “my voice” profile, or explicit user confirmation. `SpeakerIdentityEvidenceGate` never promotes model confidence to confirmed identity and blocks even a high-confidence local-voice match when the turn overlaps possible speaker playback leakage. Third-party identity therefore remains unknown or inferred until a person explicitly confirms it.

Phase 2R introduces the offline acoustic-alignment foundation for two-channel meetings. After recording has stopped, both files can be streamed into compact 100 ms energy fingerprints. Bounded cross-correlation windows estimate how much later system playback reaches the microphone and whether that offset drifts over a long meeting. Low-information or weakly correlated audio produces no reliable estimate. This phase deliberately does not erase duplicate speech, fuse transcripts, identify a speaker, or alter live recording; real two-channel fixtures must validate the estimator before its results are persisted or used automatically.

Phase 2S makes capture health explicit. The recording screen shows microphone and system-audio state independently. When system audio was requested, TwinVault verifies that the service is active after startup and persists structured warnings for startup, interruption, or finalization failure. Meeting detail continues to show those warnings after restart, including the absence of a requested system-audio file. Existing meetings migrate conservatively and are not retroactively labelled as failed when their original capture intent is unknown.

Phase 2T replaces the all-or-nothing Catalan route with a conservative regional hybrid. Trusted acoustic observations are weighted by duration: Catalan-dominant recordings still receive one whole-recording WhisperKit decode, while minority Catalan keeps a whole-recording Parakeet ES/EN baseline. Nearby Catalan observations are joined and WhisperKit receives at least twenty seconds of surrounding audio rather than isolated VAD turns; only segments centered in the confirmed Catalan interval replace the fast transcript. Failed or empty regional decodes preserve the fast evidence and add an explicit review interval. Every retained segment keeps its real provider and source recording provenance.

Phase 2U hardens that hybrid against quiet microphones and brief language changes. The adaptive energy detector accepts speech down to -60 dBFS instead of discarding valid low-level voice at the former -48 dBFS floor. Language identification keeps complete VAD turns separate and combines only turns that are too short to classify, preventing a brief Catalan turn from being hidden inside a long Spanish-dominant window. Regional WhisperKit decoding explicitly uses Catalan while retaining wide acoustic context. Parakeet still recognizes the whole file; only its post-recognition evidence grouping is shortened to three seconds so replacing a Catalan interval does not erase neighbouring Spanish words.

Phase 2V adds one post-meeting `Transcribe Meeting` action. It checks each saved channel for speech, safely skips silent channels, transcribes useful microphone and system-audio files sequentially with the selected local profile, and then calculates acoustic alignment. Only reliable alignment estimates are persisted and used to improve the existing possible-playback warning. Both transcripts remain separate evidence; no text is deleted, fused, or attributed to the user merely because it came from the microphone.

Phase 2W makes that protection independent of ASR wording. Reliable channel alignment accounts for each recorder's actual meeting start offset, then compares aligned 100 ms acoustic envelopes for every microphone transcript segment. Strong text or acoustic agreement can create an inspectable playback-leakage finding; weak evidence fails closed. Meeting detail defaults to a derived `Conversation` view that hides only flagged microphone duplicates and offers `Raw Channels` to inspect every original segment. No evidence is deleted or copied, and unflagged microphone speech still does not imply the user's identity.

Phase 2X adds explicit post-meeting speaker diarization for system audio. **Detect Speakers** runs FluidAudio's offline Community-1/VBx pipeline, persists timestamped turns with recording/provider provenance, and joins them to transcript segments by temporal overlap without modifying transcript evidence. TwinVault validates that the recording is readable before loading the model, so incomplete legacy M4A files fail with an actionable message instead of an AVFoundation status code. A second clustering pass reuses the same acoustic inference and can merge a tiny unstable fragment only when it joins a much longer speaker in the stability pass; short but consistently distinct or overlapping speakers remain separate. The first use downloads the local Core ML assets into `TwinVault/models/`; meeting audio is never uploaded. Labels such as “Speaker 1” are scoped to that meeting only: they are not names, biometric identities, or proof that the microphone speaker is the user. Microphone diarization and speaker identification remain deliberately disabled until cross-channel leakage and consented evaluation justify them.

Phase 2Y adds human review for meeting-local speaker clusters. Beside every temporary speaker, **Merge with…** records an explicit user-confirmed mapping and immediately applies it to transcript presentation. Raw diarization turns are never overwritten, **Reset Speaker Corrections** is reversible, and running diarization again discards mappings for the replaced clustering result. These corrections state only that two temporary labels represent the same voice in one meeting; they do not name a person or create biometric identity.

Phase 2Z lets the user add, edit, or remove a participant name for each reviewed speaker. The transcript shows the confirmed name together with its technical label, such as `Laura · Speaker 1`. The name is scoped to that meeting and stored separately from raw diarization evidence; it is not reused across meetings, treated as a biometric match, or promoted into a `Person` entity. Re-running diarization clears labels tied to the replaced clusters, and conflicting named clusters must be reviewed before merging.

WhisperKit is an MIT-licensed third-party dependency. Only its `WhisperKit` package product is linked; SpeakerKit, TTSKit, and speaker identification are not enabled. Apache-2.0-licensed FluidAudio 0.17.4 is pinned for experimental Parakeet transcription and offline diarization. FluidAudio currently exposes a broad package product, so it increases build size beyond the code TwinVault uses; model-asset licensing and that packaging cost must be reviewed before distribution.

## Current boundaries

`MeetingRepository` isolates the domain and UI from JSON storage. `AudioRecordingService` isolates recording and permission handling from presentation. Apple Speech, WhisperKit, Parakeet, experimental Nemotron, and the conservative automatic router are replaceable implementations of `SpeechToTextProvider`. Nemotron is deliberately not registered in the application profile list. Acoustic language identification, diarization, and speaker identification are separate contracts. FluidAudio implements only diarization; speaker identification remains unimplemented. Structured memory, twins, external integrations, and generative-AI inference remain absent.

See [ARCHITECTURE.md](ARCHITECTURE.md) for decisions and Phase 2 boundaries.
Aggregate local evaluation results are recorded in [BENCHMARKS.md](BENCHMARKS.md); private fixtures and raw transcripts are excluded.
