# TwinVault

TwinVault is a native, local-first macOS meeting memory application. It records meeting audio, keeps notes and important timestamps inspectable on-device, and can transcribe a selected local audio channel using replaceable on-device speech engines. It has no cloud inference, analytics, or audio upload.

## Current capabilities

- Create and record a meeting with explicit microphone permission.
- Show recording duration and state.
- Capture a simple note and important moments while recording.
- Store audio separately from versioned meeting metadata.
- Browse previous meetings and inspect notes, timestamps, and audio status.
- Transcribe a completed meeting locally with Spanish, Catalan, and English enabled by default.
- Choose an explicit transcription profile: multilingual ES/CA/EN (recommended, backed by WhisperKit), experimental fast ES/EN (Parakeet), or Apple Speech as the system-native comparison mode.
- See model preparation, download, loading, and local transcription states; Parakeet reports real download percentage and active work can be cancelled without replacing an existing transcript.
- Split speech at local acoustic pauses before either engine processes a language hypothesis.
- Anchor newly recorded microphone and system-audio files to the meeting timeline.
- Warn immediately if macOS interrupts system-audio capture while keeping the microphone active.
- Mark long transcript intervals without text for human review instead of presenting the transcript as complete.

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

WhisperKit is an MIT-licensed third-party dependency. Only its `WhisperKit` package product is linked; SpeakerKit, TTSKit, diarization, and speaker identification are not enabled in this increment. Apache-2.0-licensed FluidAudio 0.17.4 is pinned for the experimental Parakeet adapter. FluidAudio currently exposes a broad package product, so it increases build size beyond the ASR code TwinVault uses; that cost must be measured before production packaging.

## Current boundaries

`MeetingRepository` isolates the domain and UI from JSON storage. `AudioRecordingService` isolates recording and permission handling from presentation. Apple Speech, WhisperKit, and Parakeet are replaceable implementations of `SpeechToTextProvider`; diarization and speaker identification remain separate unimplemented contracts. Structured memory, twins, external integrations, and generative-AI inference remain absent.

See [ARCHITECTURE.md](ARCHITECTURE.md) for decisions and Phase 2 boundaries.
Aggregate local evaluation results are recorded in [BENCHMARKS.md](BENCHMARKS.md); private fixtures and raw transcripts are excluded.
