# TwinVault

TwinVault is a native, local-first macOS meeting memory application. It records meeting audio, keeps notes and important timestamps inspectable on-device, and can transcribe a selected local audio channel using replaceable on-device speech engines. It has no cloud inference, analytics, or audio upload.

## Current capabilities

- Create and record a meeting with explicit microphone permission.
- Show recording duration and state.
- Capture a simple note and important moments while recording.
- Store audio separately from versioned meeting metadata.
- Browse previous meetings and inspect notes, timestamps, and audio status.
- Transcribe a completed meeting locally with Spanish, Catalan, and English enabled by default.
- Choose WhisperKit for stronger multilingual transcription or Apple Speech as the system-native alternative.
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

WhisperKit is an MIT-licensed third-party dependency. Only its `WhisperKit` package product is linked; SpeakerKit, TTSKit, diarization, and speaker identification are not enabled in this increment.

## Current boundaries

`MeetingRepository` isolates the domain and UI from JSON storage. `AudioRecordingService` isolates recording and permission handling from presentation. Apple Speech and WhisperKit are replaceable implementations of `SpeechToTextProvider`; diarization and speaker identification remain separate unimplemented contracts. Structured memory, twins, external integrations, and generative-AI inference remain absent.

See [ARCHITECTURE.md](ARCHITECTURE.md) for decisions and Phase 2 boundaries.
Aggregate local evaluation results are recorded in [BENCHMARKS.md](BENCHMARKS.md); private fixtures and raw transcripts are excluded.
