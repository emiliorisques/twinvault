import Combine
import SwiftUI

struct MeetingsListView: View {
    @Environment(AppModel.self) private var model
    @State private var showingNewMeeting = false

    var body: some View {
        NavigationSplitView {
            List(model.meetings) { meeting in
                NavigationLink(value: meeting.id) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(meeting.title).font(.headline)
                        Text(meeting.startDate, format: .dateTime.day().month().year().hour().minute())
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Meetings")
            .toolbar {
                Button("New Meeting", systemImage: "plus") { showingNewMeeting = true }
                    .disabled(model.activeSession != nil)
            }
            .navigationDestination(for: UUID.self) { id in
                if let meeting = model.meetings.first(where: { $0.id == id }) {
                    MeetingDetailView(meeting: meeting)
                }
            }
        } detail: {
            ContentUnavailableView("Select a meeting", systemImage: "waveform")
        }
        .sheet(isPresented: $showingNewMeeting) { NewMeetingView() }
        .sheet(isPresented: Binding(
            get: { model.activeSession != nil },
            set: { _ in }
        )) { RecordingView() }
        .alert("TwinVault", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) { Button("OK") { model.errorMessage = nil } } message: {
            Text(model.errorMessage ?? "Unknown error")
        }
        .task { await model.load() }
    }
}

struct NewMeetingView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var captureSystemAudio = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("New Meeting").font(.title2.bold())
            TextField("Meeting title", text: $title).textFieldStyle(.roundedBorder)
            Toggle("Capture system audio", isOn: $captureSystemAudio)
            if captureSystemAudio {
                Text("macOS may request Screen & System Audio Recording permission. TwinVault does not capture or store video frames.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Start Recording") {
                    dismiss()
                    Task { await model.startMeeting(title: title, captureSystemAudio: captureSystemAudio) }
                }.buttonStyle(.borderedProminent)
            }
        }.padding(24).frame(width: 420)
    }
}

struct RecordingView: View {
    @Environment(AppModel.self) private var model
    @State private var noteText = ""
    @State private var now = Date.now
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if let session = model.activeSession {
                HStack {
                    Circle().fill(.red).frame(width: 10, height: 10)
                    Text("Recording").foregroundStyle(.red).fontWeight(.semibold)
                    Spacer()
                    Text(duration(now.timeIntervalSince(session.meeting.startDate))).monospacedDigit()
                }
                Text(session.meeting.title).font(.title2.bold())
                if let status = model.recordingCaptureStatus {
                    VStack(alignment: .leading, spacing: 8) {
                        captureStatusRow("Microphone", status: status.microphone)
                        captureStatusRow("System Audio", status: status.systemAudio)
                    }
                    .padding(12)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
                }
                TextEditor(text: $noteText)
                    .font(.body).frame(minHeight: 180).border(.quaternary)
                    .onChange(of: noteText) { _, value in model.updateNote(value) }
                HStack {
                    Button("Mark Important Moment", systemImage: "bookmark.fill") { model.markImportant() }
                    Spacer()
                    Button("Stop Meeting", systemImage: "stop.fill", role: .destructive) {
                        Task { await model.stopMeeting() }
                    }.buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(24).frame(minWidth: 580, minHeight: 390)
        .interactiveDismissDisabled()
        .onReceive(timer) { now = $0 }
    }

    @ViewBuilder
    private func captureStatusRow(_ channel: String, status: RecordingChannelStatus) -> some View {
        switch status {
        case .recording:
            Label("\(channel): Recording", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .notRequested:
            Label("\(channel): Not requested", systemImage: "minus.circle")
                .foregroundStyle(.secondary)
        case let .unavailable(message):
            VStack(alignment: .leading, spacing: 3) {
                Label("\(channel): Not recording", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .fontWeight(.semibold)
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct MeetingDetailView: View {
    private enum TranscriptDisplayMode: String, CaseIterable, Identifiable {
        case conversation = "Conversation"
        case rawChannels = "Raw Channels"

        var id: Self { self }
    }

    private struct SpeakerNamingTarget: Identifiable {
        let recordingID: UUID
        let identifier: String
        let currentName: String
        var id: String { "\(recordingID.uuidString)-\(identifier)" }
    }

    private struct TranscriptEditingTarget: Identifiable {
        let segment: TranscriptSegment
        let currentText: String
        var id: UUID { segment.id }
    }

    @Environment(AppModel.self) private var model
    let meeting: Meeting
    @State private var transcriptDisplayMode = TranscriptDisplayMode.conversation
    @State private var speakerNamingTarget: SpeakerNamingTarget?
    @State private var transcriptEditingTarget: TranscriptEditingTarget?

    private var conversationSegments: [TranscriptSegment] {
        MeetingConversationTranscript().segments(
            recordings: meeting.audioRecordings,
            segments: meeting.transcriptSegments,
            findings: meeting.crossChannelTranscriptFindings
        )
    }

    private var displayedSegments: [TranscriptSegment] {
        switch transcriptDisplayMode {
        case .conversation: conversationSegments
        case .rawChannels: meeting.transcriptSegments
        }
    }

    private var hiddenPlaybackCount: Int {
        meeting.transcriptSegments.count - conversationSegments.count
    }

    private var hasBothChannelTranscripts: Bool {
        let channelsWithTranscript = Set(meeting.audioRecordings.compactMap { recording in
            meeting.transcriptSegments.contains { $0.sourceRecordingID == recording.id }
                ? recording.channel
                : nil
        })
        return channelsWithTranscript.contains(.microphone)
            && channelsWithTranscript.contains(.systemAudio)
    }

    private var systemAudioRecording: AudioRecordingReference? {
        meeting.audioRecordings.first { $0.channel == .systemAudio }
    }

    private var temporarySpeakerCount: Int {
        guard let recordingID = systemAudioRecording?.id else { return 0 }
        return Set(rawTemporarySpeakerIDs.map {
            resolvedTemporarySpeakerID($0, recordingID: recordingID)
        }).count
    }

    private var rawTemporarySpeakerIDs: [String] {
        guard let recordingID = systemAudioRecording?.id else { return [] }
        return Set(meeting.diarizationTurns.compactMap { turn in
            turn.sourceRecordingID == recordingID ? turn.temporarySpeakerID : nil
        }).sorted()
    }

    private var hasSpeakerCorrections: Bool {
        guard let recordingID = systemAudioRecording?.id else { return false }
        return meeting.speakerClusterCorrections.contains { $0.sourceRecordingID == recordingID }
    }

    private var canonicalTemporarySpeakerIDs: [String] {
        guard let recordingID = systemAudioRecording?.id else { return [] }
        return Set(rawTemporarySpeakerIDs.map {
            resolvedTemporarySpeakerID($0, recordingID: recordingID)
        }).sorted()
    }

    private func resolvedTemporarySpeakerID(_ identifier: String, recordingID: UUID) -> String {
        SpeakerClusterResolver().canonicalTemporarySpeakerID(
            for: identifier,
            meetingID: meeting.id,
            sourceRecordingID: recordingID,
            corrections: meeting.speakerClusterCorrections
        )
    }

    private func speakerLabel(_ identifier: String) -> String {
        if identifier.hasPrefix("speaker-"),
           let number = identifier.split(separator: "-").last {
            return "Speaker \(number)"
        }
        return identifier
    }

    private func confirmedSpeakerName(_ identifier: String, recordingID: UUID) -> String? {
        meeting.speakerLabels.first {
            $0.sourceRecordingID == recordingID
                && $0.canonicalTemporarySpeakerID == identifier
                && $0.basis == .userConfirmed
        }?.displayName
    }

    private func reviewedSpeakerLabel(_ identifier: String, recordingID: UUID) -> String {
        guard let name = confirmedSpeakerName(identifier, recordingID: recordingID) else {
            return speakerLabel(identifier)
        }
        return "\(name) · \(speakerLabel(identifier))"
    }

    private func temporarySpeakerLabel(for segment: TranscriptSegment) -> String? {
        guard let identifier = TranscriptSpeakerAttribution().temporarySpeakerID(
            for: segment,
            turns: meeting.diarizationTurns,
            corrections: meeting.speakerClusterCorrections
        ) else { return nil }
        guard let recordingID = segment.sourceRecordingID else { return speakerLabel(identifier) }
        return reviewedSpeakerLabel(identifier, recordingID: recordingID)
    }

    private func transcriptCorrection(for segment: TranscriptSegment) -> TranscriptSegmentCorrection? {
        TranscriptTextResolver().correction(
            for: segment,
            corrections: meeting.transcriptCorrections
        )
    }

    private func displayedText(for segment: TranscriptSegment) -> String {
        TranscriptTextResolver().text(
            for: segment,
            corrections: meeting.transcriptCorrections
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text(meeting.title).font(.largeTitle.bold())
                LabeledContent("Started", value: meeting.startDate.formatted(date: .long, time: .shortened))
                LabeledContent("Duration", value: duration(meeting.duration))
                LabeledContent(
                    "Transcription Languages",
                    value: meeting.transcriptionLocaleIdentifiers.map(languageLabel).joined(separator: " · ")
                )
                Text("Audio Channels").font(.title2.bold())
                if meeting.requestedSystemAudioCapture,
                   !meeting.audioRecordings.contains(where: { $0.channel == .systemAudio }) {
                    Label(
                        "System audio was requested but no system-audio recording was saved.",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .foregroundStyle(.orange)
                }
                ForEach(meeting.audioCaptureIssues) { issue in
                    VStack(alignment: .leading, spacing: 3) {
                        Label(
                            "\(issue.channel.displayName) capture warning",
                            systemImage: "exclamationmark.triangle.fill"
                        )
                        .fontWeight(.semibold)
                        Text(issue.message).font(.caption)
                    }
                    .foregroundStyle(.orange)
                }
                if meeting.audioRecordings.isEmpty {
                    Text("Not available").foregroundStyle(.secondary)
                } else if model.transcribingMeetingID == meeting.id {
                    HStack {
                        if let activity = model.transcriptionActivity {
                            ProgressView().controlSize(.small)
                            Text("Transcribing meeting · \(transcriptionStatus(activity))")
                                .foregroundStyle(.secondary)
                        } else {
                            ProgressView().controlSize(.small)
                            Text("Analyzing meeting channels…")
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Cancel", role: .cancel) { model.cancelTranscription() }
                    }
                } else {
                    Menu {
                        ForEach(model.transcriptionProfiles) { profile in
                            Button {
                                model.startMeetingTranscription(
                                    meetingID: meeting.id,
                                    profileID: profile.id
                                )
                            } label: {
                                Label(
                                    profile.isRecommended
                                        ? "\(profile.displayName) — Recommended"
                                        : profile.displayName,
                                    systemImage: profile.isRecommended ? "checkmark.seal" : "waveform"
                                )
                            }
                        }
                    } label: {
                        Label("Transcribe Meeting", systemImage: "waveform.badge.magnifyingglass")
                    }
                    .disabled(model.diarizationActivity != nil)
                    .help("Detect speech, transcribe every useful channel locally, align both timelines, and flag probable speaker playback captured by the microphone.")
                    if hasBothChannelTranscripts {
                        Button("Refresh Channel Analysis", systemImage: "arrow.triangle.2.circlepath") {
                            model.startChannelAnalysis(meetingID: meeting.id)
                        }
                        .help("Recalculate alignment and playback leakage without transcribing the audio again.")
                    }
                }
                if let alignment = meeting.channelAlignmentEstimate, alignment.isReliable {
                    LabeledContent(
                        "Channel alignment",
                        value: "Microphone delay \(duration(alignment.microphoneDelayAtStart)) · \(Int((alignment.confidence * 100).rounded()))% confidence"
                    )
                }
                ForEach(meeting.audioRecordings) { recording in
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(recording.channel.displayName).fontWeight(.medium)
                            Text(recording.relativePath).font(.caption).foregroundStyle(.secondary)
                            if let offset = recording.meetingTimelineOffset {
                                Text("Timeline +\(duration(offset))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Button(
                            model.playingRecordingID == recording.id ? "Stop" : "Play",
                            systemImage: model.playingRecordingID == recording.id ? "stop.fill" : "play.fill"
                        ) {
                            Task { await model.togglePlayback(recording) }
                        }
                        if let activity = model.transcriptionActivity,
                           activity.recordingID == recording.id {
                            if let fraction = activity.progress.fractionCompleted {
                                ProgressView(value: fraction)
                                    .frame(width: 80)
                            } else {
                                ProgressView().controlSize(.small)
                            }
                            Text(transcriptionStatus(activity))
                                .foregroundStyle(.secondary)
                            Button("Cancel", role: .cancel) {
                                model.cancelTranscription()
                            }
                        } else {
                            Menu {
                                ForEach(model.transcriptionProfiles) { profile in
                                    Button {
                                        model.startTranscription(
                                            meetingID: meeting.id,
                                            recordingID: recording.id,
                                            profileID: profile.id
                                        )
                                    } label: {
                                        Label(
                                            profile.isRecommended
                                                ? "\(profile.displayName) — Recommended"
                                                : profile.displayName,
                                            systemImage: profile.isRecommended ? "checkmark.seal" : "waveform"
                                        )
                                    }
                                    .help(profile.detail)
                                }
                            } label: {
                                Label(
                                    meeting.transcriptSegments.contains { $0.sourceRecordingID == recording.id }
                                        ? "Transcribe Again" : "Transcribe",
                                    systemImage: "text.bubble"
                                )
                            }
                            .disabled(
                                model.transcriptionActivity != nil
                                    || model.transcribingMeetingID != nil
                                    || model.diarizationActivity != nil
                            )
                            .help("Choose a local transcription profile. The recommended profile supports mixed Spanish, Catalan, and English.")
                        }
                    }
                }
                if systemAudioRecording != nil, model.canDiarizeLocally {
                    Divider()
                    Text("Temporary Speakers").font(.title2.bold())
                    if let activity = model.diarizationActivity,
                       activity.meetingID == meeting.id {
                        HStack {
                            if let fraction = activity.progress.fractionCompleted {
                                ProgressView(value: fraction).frame(width: 100)
                            } else {
                                ProgressView().controlSize(.small)
                            }
                            Text(diarizationStatus(activity.progress))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("Cancel", role: .cancel) { model.cancelDiarization() }
                        }
                    } else {
                        HStack {
                            Button(
                                meeting.diarizationTurns.isEmpty
                                    ? "Detect Speakers" : "Detect Speakers Again",
                                systemImage: "person.2.wave.2"
                            ) {
                                model.startSystemAudioDiarization(meetingID: meeting.id)
                            }
                            .disabled(
                                model.transcriptionActivity != nil
                                    || model.transcribingMeetingID != nil
                            )
                            if temporarySpeakerCount > 0 {
                                Text("\(temporarySpeakerCount) reviewed speaker\(temporarySpeakerCount == 1 ? "" : "s")")
                                    .foregroundStyle(.secondary)
                            }
                        }
                        if let recordingID = systemAudioRecording?.id {
                            ForEach(canonicalTemporarySpeakerIDs, id: \.self) { identifier in
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(reviewedSpeakerLabel(identifier, recordingID: recordingID))
                                            .fontWeight(.medium)
                                        if confirmedSpeakerName(identifier, recordingID: recordingID) != nil {
                                            Text("Name confirmed by user for this meeting")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                    Spacer()
                                    Button(
                                        confirmedSpeakerName(identifier, recordingID: recordingID) == nil
                                            ? "Add Name" : "Edit Name"
                                    ) {
                                        speakerNamingTarget = SpeakerNamingTarget(
                                            recordingID: recordingID,
                                            identifier: identifier,
                                            currentName: confirmedSpeakerName(
                                                identifier,
                                                recordingID: recordingID
                                            ) ?? ""
                                        )
                                    }
                                    if confirmedSpeakerName(identifier, recordingID: recordingID) != nil {
                                        Button("Remove Name", role: .destructive) {
                                            Task {
                                                await model.removeTemporarySpeakerName(
                                                    meetingID: meeting.id,
                                                    sourceRecordingID: recordingID,
                                                    temporarySpeakerID: identifier
                                                )
                                            }
                                        }
                                    }
                                }
                            }
                            if rawTemporarySpeakerIDs.count > 1 {
                                Text("Cluster corrections")
                                    .font(.headline)
                                    .padding(.top, 4)
                            }
                            ForEach(rawTemporarySpeakerIDs, id: \.self) { identifier in
                                let resolved = resolvedTemporarySpeakerID(
                                    identifier,
                                    recordingID: recordingID
                                )
                                HStack {
                                    Text(speakerLabel(identifier))
                                    if resolved != identifier {
                                        Label(
                                            "Same as \(speakerLabel(resolved))",
                                            systemImage: "person.2.fill"
                                        )
                                        .font(.caption)
                                        .foregroundStyle(.green)
                                    }
                                    Spacer()
                                    Menu("Merge with…") {
                                        ForEach(
                                            rawTemporarySpeakerIDs.filter { $0 != identifier },
                                            id: \.self
                                        ) { target in
                                            Button("Same as \(speakerLabel(target))") {
                                                Task {
                                                    await model.mergeTemporarySpeaker(
                                                        meetingID: meeting.id,
                                                        sourceRecordingID: recordingID,
                                                        sourceTemporarySpeakerID: identifier,
                                                        into: target
                                                    )
                                                }
                                            }
                                        }
                                    }
                                    .disabled(rawTemporarySpeakerIDs.count < 2)
                                }
                            }
                            if hasSpeakerCorrections {
                                Button("Reset Speaker Corrections", role: .destructive) {
                                    Task {
                                        await model.resetSpeakerCorrections(
                                            meetingID: meeting.id,
                                            sourceRecordingID: recordingID
                                        )
                                    }
                                }
                            }
                        }
                        Text("Runs locally on system audio. Labels are valid only inside this meeting and are not person identities. The first run downloads the local model.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if !rawTemporarySpeakerIDs.isEmpty {
                            Text("Names and merges are explicit user-confirmed labels for this meeting. Original model turns are preserved, and no biometric identity is created.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                Divider()
                Text("Transcript").font(.title2.bold())
                if meeting.transcriptSegments.isEmpty {
                    Text("Not transcribed").foregroundStyle(.secondary)
                } else {
                    Picker("Transcript view", selection: $transcriptDisplayMode) {
                        ForEach(TranscriptDisplayMode.allCases) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    if transcriptDisplayMode == .conversation, hiddenPlaybackCount > 0 {
                        Label(
                            "\(hiddenPlaybackCount) microphone playback duplicate\(hiddenPlaybackCount == 1 ? "" : "s") hidden. Original channel evidence is preserved.",
                            systemImage: "checkmark.shield"
                        )
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    }
                    if !meeting.transcriptReviewIntervals.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Label("Review transcript", systemImage: "exclamationmark.triangle.fill")
                                .fontWeight(.semibold)
                            ForEach(meeting.transcriptReviewIntervals) { interval in
                                switch interval.reason {
                                case .longUntranscribedInterval:
                                    Text("No transcript from \(duration(interval.startTime)) to \(duration(interval.endTime)); this may be silence or missed speech.")
                                        .font(.caption)
                                case .regionalLanguageVerificationFailed:
                                    Text("Catalan was detected from \(duration(interval.startTime)) to \(duration(interval.endTime)), but the Catalan verification pass returned no replacement. The fast transcript was retained.")
                                        .font(.caption)
                                }
                            }
                        }
                        .foregroundStyle(.orange)
                    }
                    if transcriptDisplayMode == .rawChannels,
                       !meeting.crossChannelTranscriptFindings.isEmpty {
                        Label(
                            "Possible speaker playback was also captured by the microphone. It remains unassigned and will not be treated as your voice.",
                            systemImage: "speaker.wave.2.trianglebadge.exclamationmark"
                        )
                        .font(.callout)
                        .foregroundStyle(.orange)
                    }
                    ForEach(displayedSegments) { segment in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 8) {
                                Text("\(duration(segment.startTime))–\(duration(segment.endTime))")
                                    .monospacedDigit()
                                if let recordingID = segment.sourceRecordingID,
                                   let channel = meeting.audioRecordings.first(where: { $0.id == recordingID })?.channel {
                                    Text(channel.displayName)
                                }
                                if let localeIdentifier = segment.localeIdentifier {
                                    Text(languageLabel(localeIdentifier)).fontWeight(.semibold)
                                }
                                if let speaker = temporarySpeakerLabel(for: segment) {
                                    Text(speaker)
                                        .fontWeight(.semibold)
                                        .foregroundStyle(.blue)
                                }
                                if meeting.crossChannelTranscriptFindings.contains(where: {
                                    $0.microphoneSegmentID == segment.id
                                }) {
                                    Text("Possible playback leakage")
                                        .fontWeight(.semibold)
                                        .foregroundStyle(.orange)
                                }
                                if transcriptCorrection(for: segment) != nil {
                                    Label("User confirmed", systemImage: "checkmark.seal.fill")
                                        .fontWeight(.semibold)
                                        .foregroundStyle(.green)
                                }
                                Spacer()
                                Button("Play from timestamp", systemImage: "play.circle") {
                                    Task {
                                        await model.playTranscriptSegment(
                                            meetingID: meeting.id,
                                            segmentID: segment.id
                                        )
                                    }
                                }
                                .labelStyle(.iconOnly)
                                .help("Play source audio from \(duration(segment.startTime))")
                                Button("Correct Transcript", systemImage: "pencil") {
                                    transcriptEditingTarget = TranscriptEditingTarget(
                                        segment: segment,
                                        currentText: displayedText(for: segment)
                                    )
                                }
                                .labelStyle(.iconOnly)
                                .help("Review or correct this transcript segment")
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            if let provider = segment.providerIdentifier {
                                Text("Provider: \(provider)")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Text(displayedText(for: segment)).textSelection(.enabled)
                            if let correction = transcriptCorrection(for: segment) {
                                Text("Original: \(correction.originalText)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                                Button("Undo Correction", role: .destructive) {
                                    Task {
                                        await model.resetTranscriptCorrection(
                                            meetingID: meeting.id,
                                            segmentID: segment.id
                                        )
                                    }
                                }
                                .font(.caption)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
                Divider()
                Text("Notes").font(.title2.bold())
                Text(meeting.notes.first?.text.isEmpty == false ? meeting.notes.first!.text : "No notes")
                    .textSelection(.enabled)
                Divider()
                Text("Important Moments").font(.title2.bold())
                if meeting.importantMoments.isEmpty { Text("No important moments").foregroundStyle(.secondary) }
                ForEach(meeting.importantMoments) { moment in
                    Label(duration(moment.elapsedTime), systemImage: "bookmark.fill")
                }
            }.padding(28).frame(maxWidth: 760, alignment: .leading)
        }
        .navigationTitle(meeting.title)
        .sheet(item: $speakerNamingTarget) { target in
            SpeakerNameEditor(
                speakerLabel: speakerLabel(target.identifier),
                initialName: target.currentName
            ) { name in
                Task {
                    await model.assignTemporarySpeakerName(
                        meetingID: meeting.id,
                        sourceRecordingID: target.recordingID,
                        temporarySpeakerID: target.identifier,
                        displayName: name
                    )
                }
            }
        }
        .sheet(item: $transcriptEditingTarget) { target in
            TranscriptCorrectionEditor(
                segment: target.segment,
                initialText: target.currentText
            ) { correctedText in
                Task {
                    await model.correctTranscriptSegment(
                        meetingID: meeting.id,
                        segmentID: target.segment.id,
                        correctedText: correctedText
                    )
                }
            }
        }
    }
}

private struct SpeakerNameEditor: View {
    @Environment(\.dismiss) private var dismiss
    let speakerLabel: String
    let onSave: (String) -> Void
    @State private var name: String

    init(speakerLabel: String, initialName: String, onSave: @escaping (String) -> Void) {
        self.speakerLabel = speakerLabel
        self.onSave = onSave
        _name = State(initialValue: initialName)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Name \(speakerLabel)").font(.title2.bold())
            Text("This label applies only to this meeting and is confirmed by you.")
                .font(.callout)
                .foregroundStyle(.secondary)
            TextField("Participant name", text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit(save)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save", action: save)
                    .buttonStyle(.borderedProminent)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 400)
    }

    private func save() {
        onSave(name)
        dismiss()
    }
}

private struct TranscriptCorrectionEditor: View {
    @Environment(\.dismiss) private var dismiss
    let segment: TranscriptSegment
    let onSave: (String) -> Void
    @State private var text: String

    init(
        segment: TranscriptSegment,
        initialText: String,
        onSave: @escaping (String) -> Void
    ) {
        self.segment = segment
        self.onSave = onSave
        _text = State(initialValue: initialText)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Correct Transcript").font(.title2.bold())
            Text("Audio \(duration(segment.startTime))–\(duration(segment.endTime))")
                .font(.callout)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 5) {
                Text("Original model text").font(.caption).fontWeight(.semibold)
                Text(segment.text).textSelection(.enabled)
            }
            .padding(10)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
            TextEditor(text: $text)
                .font(.body)
                .frame(minHeight: 150)
                .border(.quaternary)
            Text("Saving creates a reversible user-confirmed correction. The original model text remains unchanged.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save Correction") {
                    onSave(text)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 560)
    }
}

private func duration(_ interval: TimeInterval) -> String {
    let seconds = max(0, Int(interval))
    return String(format: "%02d:%02d:%02d", seconds / 3600, (seconds % 3600) / 60, seconds % 60)
}

private func languageLabel(_ localeIdentifier: String) -> String {
    localeIdentifier.split(whereSeparator: { $0 == "-" || $0 == "_" })
        .first.map { String($0).uppercased() } ?? localeIdentifier
}

private func transcriptionStatus(_ activity: TranscriptionActivity) -> String {
    switch activity.progress.stage {
    case .preparingModel:
        return "Preparing \(activity.profileName)…"
    case .downloadingModel:
        if let fraction = activity.progress.fractionCompleted {
            return "Downloading model \(Int(fraction * 100))%"
        }
        return "Downloading model…"
    case .loadingModel:
        return "Loading local model…"
    case .identifyingLanguage:
        return "Detecting spoken languages locally…"
    case .transcribing:
        return "Transcribing locally…"
    }
}

private func diarizationStatus(_ progress: DiarizationProgress) -> String {
    switch progress.stage {
    case .preparingModel:
        return "Preparing local speaker model…"
    case .downloadingModel:
        if let fraction = progress.fractionCompleted {
            return "Downloading speaker model \(Int(fraction * 100))%"
        }
        return "Downloading speaker model…"
    case .loadingModel:
        return "Loading local speaker model…"
    case .analyzingSpeakers:
        return "Detecting temporary speakers locally…"
    }
}
