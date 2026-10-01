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
    @Environment(AppModel.self) private var model
    let meeting: Meeting

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
                            .disabled(model.transcribingRecordingID != nil)
                            .help("Choose a local transcription profile. The recommended profile supports mixed Spanish, Catalan, and English.")
                        }
                    }
                }
                Divider()
                Text("Transcript").font(.title2.bold())
                if meeting.transcriptSegments.isEmpty {
                    Text("Not transcribed").foregroundStyle(.secondary)
                } else {
                    if !meeting.transcriptReviewIntervals.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Label("Review transcript coverage", systemImage: "exclamationmark.triangle.fill")
                                .fontWeight(.semibold)
                            ForEach(meeting.transcriptReviewIntervals) { interval in
                                Text("No transcript from \(duration(interval.startTime)) to \(duration(interval.endTime)); this may be silence or missed speech.")
                                    .font(.caption)
                            }
                        }
                        .foregroundStyle(.orange)
                    }
                    if !meeting.crossChannelTranscriptFindings.isEmpty {
                        Label(
                            "Possible speaker playback was also captured by the microphone. It remains unassigned and will not be treated as your voice.",
                            systemImage: "speaker.wave.2.trianglebadge.exclamationmark"
                        )
                        .font(.callout)
                        .foregroundStyle(.orange)
                    }
                    ForEach(meeting.transcriptSegments) { segment in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 8) {
                                Text(duration(segment.startTime)).monospacedDigit()
                                if let recordingID = segment.sourceRecordingID,
                                   let channel = meeting.audioRecordings.first(where: { $0.id == recordingID })?.channel {
                                    Text(channel.displayName)
                                }
                                if let localeIdentifier = segment.localeIdentifier {
                                    Text(languageLabel(localeIdentifier)).fontWeight(.semibold)
                                }
                                if meeting.crossChannelTranscriptFindings.contains(where: {
                                    $0.microphoneSegmentID == segment.id
                                }) {
                                    Text("Possible playback leakage")
                                        .fontWeight(.semibold)
                                        .foregroundStyle(.orange)
                                }
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            Text(segment.text).textSelection(.enabled)
                        }
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
        }.navigationTitle(meeting.title)
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
