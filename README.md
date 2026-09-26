# TwinVault

TwinVault is a native, local-first macOS meeting memory application. It records meeting audio, keeps notes and important timestamps inspectable on-device, and can transcribe a selected local audio channel using Apple's on-device speech model. It has no cloud AI, analytics, or audio upload.

## Current capabilities

- Create and record a meeting with explicit microphone permission.
- Show recording duration and state.
- Capture a simple note and important moments while recording.
- Store audio separately from versioned meeting metadata.
- Browse previous meetings and inspect notes, timestamps, and audio status.

## Development

Requirements: Apple Silicon Mac, macOS 15+, Xcode 16+ (the current machine has Xcode 27), and an accepted Xcode license.

Open `TwinVault.xcodeproj`, select the `TwinVault` scheme, and Run. Tests are available with **Product > Test**. The package can also be checked with `swift test` when the selected Command Line Tools SDK matches the Swift compiler.

Runtime data is stored below `~/Library/Application Support/TwinVault/`:

```text
TwinVault/
├── database/meetings-v1.json
├── audio/<meeting UUID>.m4a
└── audio/<meeting UUID>-system.m4a
```

Metadata writes are atomic. Audio never leaves the device. Removing the application does not currently erase the vault; export and verified deletion workflows are future security work.

Phase 2B adds opt-in system audio capture through ScreenCaptureKit. System audio is written to a separate local M4A file; no screen output is registered and no video frames are stored. A permission or capture failure falls back to microphone-only recording.

Meeting details provide local Play/Stop controls for each captured channel. Playback resolves only safe filenames inside the vault audio directory and never uploads media.

Phase 2C adds post-meeting transcription through `SpeechAnalyzer` and `SpeechTranscriber` on macOS 26+. The user explicitly chooses the microphone or system-audio recording to transcribe. Apple may download the selected language model once through the system-managed `AssetInventory`; recorded audio remains on-device. Timestamped segments persist with the source recording ID, provider ID, and locale.

## Current boundaries

`MeetingRepository` isolates the domain and UI from JSON storage. `AudioRecordingService` isolates recording and permission handling from presentation. Apple Speech is one replaceable implementation of `SpeechToTextProvider`; diarization and speaker identification remain separate unimplemented contracts. Structured memory, twins, external integrations, and generative-AI inference remain absent.

See [ARCHITECTURE.md](ARCHITECTURE.md) for decisions and Phase 2 boundaries.
