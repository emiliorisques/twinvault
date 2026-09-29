# TwinVault Architecture — Phase 2K transcription progress and cancellation

## Scope

Phase 1 is one vertical slice: create a meeting, record microphone audio, annotate it, stop it, persist it locally, and inspect it later. Phase 2A evolved the data boundary for multiple audio channels and timestamped transcripts. Phase 2B implements optional local system-audio capture. Phase 2C implements user-triggered, on-device transcription of a selected recording. Phase 2D enables Spanish, Catalan, and English transcription by default. Phase 2E anchors new audio files to the meeting timeline. Phase 2F adds a second local transcription implementation using WhisperKit. Phase 2G hardens system-audio finalization and makes incomplete transcript coverage inspectable. Phase 2H gives both speech engines the same local pause-based turn boundary. Phase 2I introduces explicit transcription profiles and a safe provider-routing policy. Phase 2J integrates Parakeet as an experimental, manually selected ES/EN-only profile. Phase 2K exposes model/transcription progress and cooperative cancellation. No cloud inference or audio upload exists in the application.

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
    └── SpeechToTextProvider ─┬─ AppleSpeechTranscriptionProvider
                              ├─ WhisperKitSpeechToTextProvider
                              └─ ParakeetSpeechToTextProvider
        TranscriptionPolicy ───── profile → available provider + locales
                    │
                    └── SpeechTurnDetecting ── LocalEnergySpeechTurnDetector
                    │
                    ▼
Domain: Meeting, MeetingNote, ImportantMoment, AudioRecordingReference,
        RecordingSession, TranscriptSegment, provider protocols
```

The domain imports Foundation only. It neither knows about SwiftUI, AVFoundation, nor persistence format. UI mutation goes through `RecordingSession`, which owns meeting-state invariants. Actor-isolated persistence serializes all disk access. AVFoundation stays behind a main-actor service because microphone authorization and recording are UI-driven platform operations.

System audio uses ScreenCaptureKit with only an `.audio` stream output. TwinVault does not register a `.screen` output, so captured video frames never enter the process or vault. The current application is excluded from its own audio capture. Audio is encoded as 48 kHz stereo AAC in a channel-specific M4A file. If ScreenCaptureKit authorization or startup fails, the meeting continues with microphone audio and surfaces a warning. An `SCStreamDelegate` reports unexpected termination immediately. Stop is idempotent, M4A finalization runs even if ScreenCaptureKit's stop call throws, sample delivery and finalization share one serial queue, and a completed file is reopened with AVFoundation before acceptance.

New microphone and system-audio references persist `meetingTimelineOffset`, measured from the meeting start to the point where each capture service reports successful startup. RecordingSession creation occurs only after microphone permission is resolved. Legacy recordings decode with no timeline anchor instead of inventing an offset. The domain can map a file-relative timestamp onto the meeting timeline when an anchor exists. This is a wall-clock startup-boundary estimate; it does not yet account for encoder priming, the first sample's presentation timestamp, device latency, or clock drift. Automatic channel fusion must wait for buffer-level calibration and fixture measurements.

Playback uses `AVAudioPlayer` behind an async service boundary. Stored paths must be a single relative filename and are resolved only inside the vault audio directory; traversal and missing files are rejected before AVFoundation receives a URL.

Before transcription, `LocalEnergySpeechTurnDetector` streams 50 ms PCM windows, estimates a local noise floor, and groups active regions across pauses of at most 500 ms. This is intentionally a small replaceable VAD-like boundary, not a language detector, diarization model, or speaker identity. `LocalAudioTurnSlicer` writes lossless temporary CAF files outside the vault and deletes the whole run directory after success, failure, or cancellation. Both providers translate slice-relative results back onto the original recording timeline.

Transcription uses Apple's `SpeechAnalyzer` and `SpeechTranscriber` behind the domain-owned `SpeechToTextProvider` protocol. Every meeting stores its requested locales, defaulting to `es-ES`, `ca-ES`, and `en-US`. Because each Apple transcriber accepts one locale, the adapter resolves all three locales at runtime, installs each asset independently, and analyzes every detected speech turn with each available locale. Per-turn processing prevents one long dominant-language hypothesis from suppressing a later short language change. Successful languages still produce a persisted transcript and the output reports any skipped locale to the user. A pure selector keeps the highest-confidence hypothesis where locale results overlap. Each persisted segment records its original audio time range, source recording UUID, provider identifier, and selected locale. Re-transcribing one channel replaces only segments derived from that recording.

The selection rule is a first implementation, not an assertion that confidence scores are perfectly calibrated across languages. Its boundary and deterministic tests allow replacement without changing the domain or UI. Production readiness requires consented code-switching fixtures covering Spanish/Catalan, Spanish/English, Catalan/English, accents, overlapping speech, and silence, plus energy and latency measurements on supported Apple Silicon hardware.

WhisperKit 1.1.0 is pinned for reproducible builds and only its transcription product is linked. `WhisperKitSpeechToTextProvider` validates vault-relative audio paths and independently decodes each shared speech turn before restoring its original timestamp. `LocalWhisperKitEngine` owns the non-`Sendable` runtime inside an actor. It lazily downloads and loads Argmax's recommended `large-v3-v20240930_626MB` multilingual model only after explicit user selection, then reuses it for the process lifetime. Incremental file loading still bounds memory inside each turn. Neither Whisper's VAD chunking nor the shared turn detector is speaker diarization.

Whisper control tokens are removed before text enters the domain. The current WhisperKit result-level language is deliberately not persisted as a segment language: mixed-language evaluation showed that it is not reliable evidence for every segment. Language labels may return later only behind a separately evaluated per-segment boundary.

WhisperKit performs one bounded recovery attempt for long timestamp gaps that contain acoustic activity. Remaining gaps of eight seconds or more become persisted `TranscriptReviewInterval` records linked to the exact source recording. They are warnings, not claims that speech definitely exists: silence and music can also create uncovered intervals. Future memory extraction must treat a transcript with review intervals as incomplete evidence.

The third-party runtime is isolated behind an internal engine protocol. Unit tests substitute a deterministic fake, so CI neither accesses the network nor downloads model weights. Apple Speech remains available in the same UI for comparison and fallback. A successful new run replaces only transcript segments for the selected recording; provider provenance remains on every segment.

The UI selects a `TranscriptionProfile`, not a raw model implementation. The recommended profile requests ES/CA/EN and routes to WhisperKit; Apple Speech is retained as a clearly named system-native comparison profile. `TranscriptionPolicy` filters profiles against the providers registered at composition time and picks the recommended available profile as the deterministic default. A profile determines provider and requested locales before audio processing. Transcript text or an unreliable result-level language label can never silently switch engines. Diarization is not a language router.

`ParakeetSpeechToTextProvider` is registered only for the explicit experimental ES/EN profile. It performs a second provider-level allowlist check and rejects Catalan or any other configured language before file access and inference. FluidAudio 0.17.4 and Parakeet v3 are pinned to the versions used in the feasibility benchmarks. The model is lazily downloaded into the vault's controlled models directory only after explicit profile selection. The runtime lives behind an actor and test-only engines avoid model downloads. Word timestamps are grouped at acoustic pauses or bounded duration/word counts to create evidence-sized segments; no per-segment language is asserted. Long uncovered intervals use the same review-warning policy as WhisperKit.

`TranscriptionRequest` carries an optional `Sendable` progress sink. Providers report semantic stages without coupling the domain to SwiftUI. FluidAudio supplies Parakeet's determinate download fraction; WhisperKit and Apple Speech report indeterminate preparation/loading stages because their adapters cannot obtain a trustworthy equivalent fraction. `AppModel` owns the single active task and cancellation boundary. It checks cancellation before replacing transcript data, suppresses cancellation as a user-requested error, and keeps all previously persisted evidence unchanged. Provider cancellation is cooperative, so a Core ML call may return only after its current non-interruptible operation finishes.

## ADR-001: versioned JSON before SQLite

Phase 1 has four small aggregate types and no relational query workload. A schema-versioned JSON document with atomic replacement is transparent, testable, backup-friendly, and avoids a dependency or premature migration system. Large audio files are never placed in metadata.

The cost is whole-document reads/writes and weak multi-process support. `MeetingRepository` makes the choice reversible. Schema 2 migrates Phase 1's single microphone reference into a channel-aware array; schema 3 adds transcript segments; schema 4 stores the meeting's requested transcription locales; schema 5 adds optional audio timeline anchors; schema 6 persists transcript review intervals. Older meetings decode to the three default locales, an unknown audio offset, and no invented review findings. JSON remains acceptable for short development fixtures, but move to SQLite before storing production-volume transcripts. Domain/UI code must not change during that migration.

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

There is no external inference service. Microphone access is requested only when the user starts a meeting. `AssetInventory` may download a language model from Apple at the user's first Apple Speech request. Choosing WhisperKit or experimental Parakeet for the first time downloads public Core ML model assets from their configured model repositories into the local vault. Providers never upload meeting audio. Metadata and audio live under Application Support, and metadata uses atomic writes. The macOS application does not claim application-level encryption at rest: it currently inherits filesystem protection such as FileVault when enabled. Keychain-managed workspace keys, Apple cryptographic APIs, audit logs, export, retention, and propagation-aware deletion require a deliberate later phase.

## Concurrency

Types crossing boundaries conform to `Sendable`. The repository is an actor. Presentation and AVFoundation services are `@MainActor`. Async repository calls prevent disk work APIs from leaking callbacks into views. Strict Swift 6 checking is enabled by the toolchain.

## Next increments (not implemented)

1. Build human-corrected multilingual and cross-channel evaluation fixtures and enforce quality gates.
2. Add buffer-level host-time calibration and measure microphone/system drift.
3. Transcribe both channels while retaining independent evidence.
4. Deduplicate overlapping channel hypotheses only after timing accuracy is measured.
5. Add diarization independently and align turns through the common meeting timeline.
6. Require review/confirmation before transcript-derived facts enter Twin memory.
7. Move metadata and transcript persistence to SQLite before production-volume transcripts.

Speaker diarization and speaker identification remain distinct boundaries. Only their contracts exist; model implementations are not part of this phase.
