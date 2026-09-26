# TwinVault Architecture — Phase 2E audio timeline anchors

## Scope

Phase 1 is one vertical slice: create a meeting, record microphone audio, annotate it, stop it, persist it locally, and inspect it later. Phase 2A evolved the data boundary for multiple audio channels and timestamped transcripts. Phase 2B implements optional local system-audio capture. Phase 2C implements user-triggered, on-device transcription of a selected recording. Phase 2D enables Spanish, Catalan, and English transcription by default. Phase 2E anchors new audio files to the meeting timeline. No cloud AI or audio upload exists in the application.

## Boundaries

```text
SwiftUI Views
    │
    ▼
AppModel (use-case coordination)
    ├── MeetingRepository protocol ── JSONMeetingRepository
    ├── AudioRecordingService ── LocalAudioRecordingService
    ├── SystemAudioCaptureService ── ScreenCaptureSystemAudioService
    ├── AudioPlaybackService ── LocalAudioPlaybackService
    └── SpeechToTextProvider ── AppleSpeechTranscriptionProvider
                    │
                    ▼
Domain: Meeting, MeetingNote, ImportantMoment, AudioRecordingReference,
        RecordingSession, TranscriptSegment, provider protocols
```

The domain imports Foundation only. It neither knows about SwiftUI, AVFoundation, nor persistence format. UI mutation goes through `RecordingSession`, which owns meeting-state invariants. Actor-isolated persistence serializes all disk access. AVFoundation stays behind a main-actor service because microphone authorization and recording are UI-driven platform operations.

System audio uses ScreenCaptureKit with only an `.audio` stream output. TwinVault does not register a `.screen` output, so captured video frames never enter the process or vault. The current application is excluded from its own audio capture. Audio is encoded as 48 kHz stereo AAC in a channel-specific M4A file. If ScreenCaptureKit authorization or startup fails, the meeting continues with microphone audio and surfaces a warning.

New microphone and system-audio references persist `meetingTimelineOffset`, measured from the meeting start to the point where each capture service reports successful startup. RecordingSession creation occurs only after microphone permission is resolved. Legacy recordings decode with no timeline anchor instead of inventing an offset. The domain can map a file-relative timestamp onto the meeting timeline when an anchor exists. This is a wall-clock startup-boundary estimate; it does not yet account for encoder priming, the first sample's presentation timestamp, device latency, or clock drift. Automatic channel fusion must wait for buffer-level calibration and fixture measurements.

Playback uses `AVAudioPlayer` behind an async service boundary. Stored paths must be a single relative filename and are resolved only inside the vault audio directory; traversal and missing files are rejected before AVFoundation receives a URL.

Transcription uses Apple's `SpeechAnalyzer` and `SpeechTranscriber` behind the domain-owned `SpeechToTextProvider` protocol. Every meeting stores its requested locales, defaulting to `es-ES`, `ca-ES`, and `en-US`. Because each Apple transcriber accepts one locale, the adapter resolves all three locales at runtime, installs each asset independently, and analyzes the same local audio sequentially. Sequential processing isolates asset and analyzer failures: successful languages still produce a persisted transcript and the output reports any skipped locale to the user. A pure selector keeps the highest-confidence hypothesis where locale results overlap and coalesces adjacent same-language segments. Each persisted segment records its audio time range, source recording UUID, provider identifier, and selected locale. Re-transcribing one channel replaces only segments derived from that recording.

The selection rule is a first implementation, not an assertion that confidence scores are perfectly calibrated across languages. Its boundary and deterministic tests allow replacement without changing the domain or UI. Production readiness requires consented code-switching fixtures covering Spanish/Catalan, Spanish/English, Catalan/English, accents, overlapping speech, and silence, plus energy and latency measurements on supported Apple Silicon hardware.

## ADR-001: versioned JSON before SQLite

Phase 1 has four small aggregate types and no relational query workload. A schema-versioned JSON document with atomic replacement is transparent, testable, backup-friendly, and avoids a dependency or premature migration system. Large audio files are never placed in metadata.

The cost is whole-document reads/writes and weak multi-process support. `MeetingRepository` makes the choice reversible. Schema 2 migrates Phase 1's single microphone reference into a channel-aware array; schema 3 adds transcript segments; schema 4 stores the meeting's requested transcription locales; schema 5 adds optional audio timeline anchors. Older meetings decode to the three default locales and an unknown audio offset. JSON remains acceptable for short development fixtures, but move to SQLite before storing production-volume transcripts. Domain/UI code must not change during that migration.

## Data integrity and provenance

- UUIDs are stable identifiers.
- Notes, important moments, and audio references carry their parent `meetingID`.
- Transcript segments identify the exact source recording, provider, locale, and audio time range.
- New audio references record their approximate offset on the meeting timeline; legacy offsets remain explicitly unknown.
- Important moments store elapsed source time, enabling later audio/transcript evidence links.
- Paths stored in metadata are relative to the controlled audio directory.
- Meeting completion is idempotent and end time cannot precede start time.
- Store schema version is validated before decoding is accepted.

This is provenance scaffolding, not the future Memory model. Facts, inferences, twins, and biometric identity are intentionally absent.

## Privacy and security posture

There is no application networking or external inference service. Microphone access is requested only when the user starts a meeting. `AssetInventory` may download a language model from Apple at the user's first transcription request; SpeechAnalyzer does not send recorded voice data to Apple. Metadata and audio live under Application Support. Metadata uses atomic writes and platform data-protection options. This is not a claim of full encryption at rest: Keychain-managed workspace keys, Apple cryptographic APIs, audit logs, export, retention, and propagation-aware deletion require a deliberate later phase.

## Concurrency

Types crossing boundaries conform to `Sendable`. The repository is an actor. Presentation and AVFoundation services are `@MainActor`. Async repository calls prevent disk work APIs from leaking callbacks into views. Strict Swift 6 checking is enabled by the toolchain.

## Phase 2 next increment (not implemented)

1. Add buffer-level host-time calibration and measure microphone/system drift.
2. Build consented multilingual and cross-channel evaluation fixtures.
3. Add a replaceable WhisperKit provider and explicit local-model management.
4. Add VAD, then transcribe both channels while retaining independent evidence.
5. Deduplicate overlapping channel hypotheses only after timing accuracy is measured.
6. Add diarization independently and align turns through the common meeting timeline.
7. Move metadata and transcript persistence to SQLite before production-volume transcripts.

Speaker diarization and speaker identification remain distinct boundaries. Only their contracts exist; model implementations are not part of this phase.
