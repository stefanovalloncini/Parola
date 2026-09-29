import SwiftUI
import ParolaCore

struct RecordingPane: View {
    let source: AppModel.RecordSource
    @Environment(AppModel.self) private var model

    private var isStreaming: Bool { model.liveTakeIsStreaming }
    private var stopTitle: String {
        isStreaming ? String(localized: "Finish") : String(localized: "Stop")
    }

    @ViewBuilder
    private var card: some View {
        RecordingCard(
            source: source,
            startedAt: model.recordingStartedAt,
            arming: model.takeArming,
            isVoiceActive: model.liveVoiceActive,
            stopTitle: stopTitle,
            levelMeter: model.recordingLevelMeter,
            levelTrace: model.recordingLevelTrace,
            onStop: { model.stopRecordingAndTranscribe() },
            onCancel: { model.cancelRecordingBeforeCapture() }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            if isStreaming {
                card
                    .padding(.horizontal, DS.Spacing.large)
                    .padding(.top, DS.Spacing.large)
                    .padding(.bottom, DS.Spacing.medium)
                banners
                Divider()
                LiveTranscriptView()
            } else {
                card.frame(maxWidth: .infinity, maxHeight: .infinity)
                banners
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Recording from \(source.label.lowercased())")
    }

    @ViewBuilder
    private var banners: some View {
        if model.recordingIsSilent { silenceBanner }
        if model.recordingDiskSpaceLow { diskSpaceBanner }
    }

    private var silenceBanner: some View {
        warningBanner(icon: "speaker.slash.fill", message: silenceMessage)
    }

    private var silenceMessage: LocalizedStringKey {
        switch source {
        case .microphone: return "No voice detected — check your microphone."
        case .systemAudio: return "No sound from your Mac — check that audio is playing."
        }
    }

    private var diskSpaceBanner: some View {
        warningBanner(icon: "internaldrive", message: "Low disk space — recording stops automatically below 200 MB.")
    }

    private func warningBanner(icon: String, message: LocalizedStringKey) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(.white)
            Text(message)
                .font(DS.Font.bodyStrong)
                .foregroundStyle(.white)
            Spacer()
        }
        .padding(.horizontal, DS.Spacing.regular)
        .padding(.vertical, DS.Spacing.small)
        .background(
            Capsule().fill(DS.Palette.warning.opacity(0.85))
        )
        .padding(.horizontal, DS.Spacing.large)
        .padding(.bottom, DS.Spacing.medium)
        .transition(.opacity)
    }
}

struct RecordingCard: View {
    let source: AppModel.RecordSource
    /// Nil until the take captures its first audio.
    let startedAt: Date?
    let arming: AppModel.TakeArming?
    let isVoiceActive: Bool
    let stopTitle: String
    var levelMeter: LevelMeter? = nil
    var levelTrace: LevelTrace? = nil
    let onStop: () -> Void
    let onCancel: () -> Void
    @ScaledMetric(relativeTo: .largeTitle) private var iconSize: CGFloat = 64

    private static let cardRadius: CGFloat = 16
    private static let readoutHeight: CGFloat = 28

    var body: some View {
        VStack(spacing: DS.Spacing.large) {
            ZStack {
                Circle()
                    .fill(DS.Color.accent.opacity(0.12))
                    .frame(width: 120, height: 120)
                Image(systemName: source.systemImage)
                    .font(.system(size: iconSize, weight: .regular))
                    .foregroundStyle(DS.Color.accent)
            }

            VStack(spacing: DS.Spacing.small) {
                if let startedAt {
                    clock(from: startedAt)
                    HStack(spacing: 6) {
                        Circle()
                            .fill(isVoiceActive ? DS.Color.accent : DS.Color.secondaryText.opacity(0.5))
                            .frame(width: 6, height: 6)
                        Text("Recording")
                            .font(DS.Font.heading)
                            .foregroundStyle(DS.Color.secondaryText)
                    }
                } else {
                    armingReadout
                }
                WaveformHistory(
                    meter: levelMeter,
                    trace: levelTrace,
                    capacity: AppModel.takeLevelHistoryCapacity,
                    barWidth: 2,
                    spacing: 2,
                    maxHeight: 28,
                    idleHeight: 3,
                    fill: DS.Color.accent
                )
                .frame(width: 220, height: 30)
                .padding(.top, DS.Spacing.hair)
                Text(source.meterLabel)
                    .font(DS.Font.secondary)
                    .foregroundStyle(DS.Color.secondaryText.opacity(0.7))
            }

            if startedAt == nil {
                Button("Cancel", action: onCancel)
                    .buttonStyle(DSPillButtonStyle(kind: .secondary))
                    .keyboardShortcut(.cancelAction)
                    .axLeaf("Recording.Button.Cancel")
            } else {
                Button(action: onStop) {
                    Text(stopTitle)
                        .font(DS.Font.bodyStrong)
                        .foregroundStyle(.white)
                        .frame(width: 120, height: 36)
                        .background(
                            Capsule().fill(DS.Color.danger.opacity(0.9))
                        )
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.return)
                .axLeaf("Recording.Button.Stop")
            }
        }
        .padding(DS.Spacing.xlarge)
        .frame(width: 360)
        .background(
            RoundedRectangle(cornerRadius: Self.cardRadius, style: .continuous)
                .fill(DS.Color.surfaceElevated)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Self.cardRadius, style: .continuous)
                .stroke(DS.Color.separator.opacity(0.6), lineWidth: 1)
        )
    }

    private func clock(from startedAt: Date) -> some View {
        TimelineView(.periodic(from: startedAt, by: 1)) { context in
            Text(verbatim: AppFormat.elapsed(context.date.timeIntervalSince(startedAt)))
                .font(DS.Font.timer)
                .foregroundStyle(DS.Color.primaryText)
        }
        .frame(height: Self.readoutHeight)
    }

    /// Where the clock and "Recording" go once audio arrives: until then the take hasn't started, and says why.
    private var armingReadout: some View {
        VStack(spacing: DS.Spacing.small) {
            Group {
                if case .preparingModel(_, let download?) = arming {
                    Text(AppFormat.percent(download))
                        .font(DS.Font.timer)
                        .foregroundStyle(DS.Color.primaryText)
                } else {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .frame(height: Self.readoutHeight)
            armingLabel
                .font(DS.Font.heading)
                .foregroundStyle(DS.Color.secondaryText)
                .multilineTextAlignment(.center)
        }
        .accessibilityElement(children: .combine)
    }

    private var armingLabel: Text {
        guard case .preparingModel(let name, _) = arming else { return Text("Starting…") }
        return Text("Preparing \(ModelPickerView.shortLabel(for: AppModel.modelLabel(name)))…")
    }
}

struct LiveTranscriptView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isAwaitingSpeech: Bool {
        model.liveSegments.isEmpty && model.livePartialText.isEmpty
    }

    var body: some View {
        if isAwaitingSpeech {
            placeholder
        } else {
            transcript
        }
    }

    private static let placeholderGlyphSize: CGFloat = 30

    private var placeholder: some View {
        VStack(spacing: DS.Spacing.small) {
            Image(systemName: "waveform")
                .font(.system(size: Self.placeholderGlyphSize))
                .symbolEffect(.variableColor.iterative, isActive: !reduceMotion)
                .accessibilityHidden(true)
            Text("Your transcript appears here as you speak")
                .font(DS.Font.secondary)
                .multilineTextAlignment(.center)
        }
        .foregroundStyle(DS.Color.secondaryText.opacity(0.6))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(DS.Spacing.large)
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: DS.Spacing.small) {
                    ForEach(model.liveSegments) { seg in
                        Text(seg.text)
                            .font(DS.Font.transcript)
                            .lineSpacing(DS.Spacing.transcriptLeading)
                            .foregroundStyle(DS.Color.primaryText)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(seg.id)
                    }
                    if !model.livePartialText.isEmpty {
                        Text(model.livePartialText)
                            .font(DS.Font.transcript)
                            .lineSpacing(DS.Spacing.transcriptLeading)
                            .foregroundStyle(DS.Color.secondaryText.opacity(0.7))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id("__partial")
                    }
                }
                .padding(.horizontal, DS.Spacing.large)
                .padding(.bottom, DS.Spacing.large)
            }
            .onChange(of: model.liveSegments.count) { _, _ in
                scrollToTail(proxy)
            }
            .onChange(of: model.livePartialText) { _, _ in
                scrollToTail(proxy)
            }
        }
    }

    private func scrollToTail(_ proxy: ScrollViewProxy) {
        if !model.livePartialText.isEmpty {
            proxy.scrollTo("__partial", anchor: .bottom)
        } else if let last = model.liveSegments.last {
            proxy.scrollTo(last.id, anchor: .bottom)
        }
    }
}
