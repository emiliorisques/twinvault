# TwinVault

TwinVault is a native, local-first macOS meeting memory application. Phase 1 records microphone audio locally and keeps meeting notes and important timestamps inspectable on-device. It has no AI, cloud, analytics, transcription, or network dependency.

## Phase 1 capabilities

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
└── audio/<meeting UUID>.m4a
```

Metadata writes are atomic. Audio never leaves the device. Removing the application does not currently erase the vault; export and verified deletion workflows are future security work.

## Current boundaries

`MeetingRepository` isolates the domain and UI from JSON storage. `AudioRecordingService` isolates recording and permission handling from presentation. Structured memory, transcripts, twins, external integrations, and all AI providers are deliberately absent from Phase 1.

See [ARCHITECTURE.md](ARCHITECTURE.md) for decisions and Phase 2 boundaries.
