import Combine
import SwiftUI

struct RecordingPane: View {
    let source: AppModel.RecordSource
    @Environment(AppModel.self) private var model
    @State private var startedAt: Date = Date()

    private var isStreaming: Bool { source == .microphone && model.useStreaming }
    private var stateLabel: String { String(localized: "Recording") }
    private var stopTitle: String {
        isStreaming ? String(localized: "Finish") : String(localized: "Stop")
    }
    private var showsWaveform: Bool { source == .microphone }

    @ViewBuilder
    private var card: some View {
        RecordingCard(
            stateLabel: stateLabel,
            source: source,
            startedAt: startedAt,
            isVoiceActive: model.liveVoiceActive,
            stopTitle: stopTitle,
            levelSubject: model.recordingAudioLevel,
            showsWaveform: showsWaveform,
            onStop: { model.stopRecordingAndTranscribe() }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            if isStreaming {
                card
                    .padding(.horizontal, DS.Spacing.large)
                    .padding(.top, DS.Spacing.large)
                    .padding(.bottom, DS.Spacing.medium)
                if model.recordingIsSilent { silenceBanner }
                if model.recordingDiskSpaceLow { diskSpaceBanner }
                Divider()
                LiveTranscriptView()
            } else {
                card.frame(maxWidth: .infinity, maxHeight: .infinity)
                if model.recordingDiskSpaceLow { diskSpaceBanner }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { startedAt = Date() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Recording from \(source.label.lowercased())")
    }

    private var silenceBanner: some View {
        warningBanner(icon: "speaker.slash.fill", message: "No voice detected — check your microphone.")
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
    let stateLabel: String
    let source: AppModel.RecordSource
    let startedAt: Date
    let isVoiceActive: Bool
    let stopTitle: String
    var levelSubject: CurrentValueSubject<Float, Never>? = nil
    var showsWaveform: Bool = false
    let onStop: () -> Void
    @ScaledMetric(relativeTo: .largeTitle) private var iconSize: CGFloat = 64

    private static let cardRadius: CGFloat = 16

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
                TimelineView(.periodic(from: startedAt, by: 1)) { context in
                    let elapsed = Int(context.date.timeIntervalSince(startedAt))
                    Text(String(format: "%02d:%02d", elapsed / 60, elapsed % 60))
                        .font(DS.Font.timer)
                        .foregroundStyle(DS.Color.primaryText)
                }
                HStack(spacing: 6) {
                    Circle()
                        .fill(isVoiceActive ? DS.Color.accent : DS.Color.secondaryText.opacity(0.5))
                        .frame(width: 6, height: 6)
                    Text(stateLabel)
                        .font(DS.Font.heading)
                        .foregroundStyle(DS.Color.secondaryText)
                }
                if showsWaveform, let levelSubject {
                    LiveRecordingWaveform(levelSubject: levelSubject)
                        .frame(width: 220, height: 30)
                        .padding(.top, DS.Spacing.hair)
                }
                Text(source.label)
                    .font(DS.Font.secondary)
                    .foregroundStyle(DS.Color.secondaryText.opacity(0.7))
            }

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
}

private struct LiveRecordingWaveform: View {
    let levelSubject: CurrentValueSubject<Float, Never>
    @State private var level: Float = 0
    var body: some View {
        WaveformHistory(
            level: level,
            capacity: 48,
            barWidth: 2,
            spacing: 2,
            maxHeight: 28,
            idleHeight: 3,
            fill: DS.Color.accent
        )
        .onReceive(levelSubject.throttle(for: .milliseconds(45), scheduler: DispatchQueue.main, latest: true)) { level = $0 }
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
                        Text(seg.text.trimmingCharacters(in: .whitespaces))
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
