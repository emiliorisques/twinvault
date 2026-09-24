# TwinVault Architecture — Phase 1

## Scope

Phase 1 is one vertical slice: create a meeting, record microphone audio, annotate it, stop it, persist it locally, and inspect it later. No AI or network capability exists in the application.

## Boundaries

```text
SwiftUI Views
    │
    ▼
AppModel (use-case coordination)
    ├── MeetingRepository protocol ── JSONMeetingRepository
    └── AudioRecordingService protocol ── LocalAudioRecordingService
             │
             ▼
Domain: Meeting, MeetingNote, ImportantMoment, AudioRecordingReference,
        RecordingSession
```

The domain imports Foundation only. It neither knows about SwiftUI, AVFoundation, nor persistence format. UI mutation goes through `RecordingSession`, which owns meeting-state invariants. Actor-isolated persistence serializes all disk access. AVFoundation stays behind a main-actor service because microphone authorization and recording are UI-driven platform operations.

## ADR-001: versioned JSON before SQLite

Phase 1 has four small aggregate types and no relational query workload. A schema-versioned JSON document with atomic replacement is transparent, testable, backup-friendly, and avoids a dependency or premature migration system. Large audio files are never placed in metadata.

The cost is whole-document reads/writes and weak multi-process support. `MeetingRepository` makes the choice reversible. Move to SQLite when transcript segments introduce volume, relational evidence queries, incremental updates, or migration needs. Domain/UI code must not change during that migration.

## Data integrity and provenance

- UUIDs are stable identifiers.
- Notes, important moments, and audio references carry their parent `meetingID`.
- Important moments store elapsed source time, enabling later audio/transcript evidence links.
- Paths stored in metadata are relative to the controlled audio directory.
- Meeting completion is idempotent and end time cannot precede start time.
- Store schema version is validated before decoding is accepted.

This is provenance scaffolding, not the future Memory model. Facts, inferences, twins, and biometric identity are intentionally absent.

## Privacy and security posture

There is no networking code. Microphone access is requested only when the user starts a meeting. Metadata and audio live under Application Support. Metadata uses atomic writes and platform data-protection options. This is not a claim of full encryption at rest: Keychain-managed workspace keys, Apple cryptographic APIs, audit logs, export, retention, and propagation-aware deletion require a deliberate later phase.

## Concurrency

Types crossing boundaries conform to `Sendable`. The repository is an actor. Presentation and AVFoundation services are `@MainActor`. Async repository calls prevent disk work APIs from leaking callbacks into views. Strict Swift 6 checking is enabled by the toolchain.

## Phase 2 proposal (not implemented)

1. Add system-audio capture and explicit channel/source metadata.
2. Introduce model-neutral `SpeechToTextProvider` and timestamped `TranscriptSegment` domain types.
3. Benchmark an on-device transcription adapter behind that protocol.
4. Stream or batch transcript persistence in SQLite once volume justifies migration.
5. Add fixtures and tests for channel synchronization, provider cancellation, timestamps, and transcript provenance.

Speaker diarization and speaker identification remain distinct future boundaries and are not part of Phase 2 unless separately approved.
