import SwiftUI

struct RecordingPane: View {
    let source: AppModel.RecordSource
    @EnvironmentObject var model: AppModel
    @State private var startedAt: Date = Date()

    private var isStreaming: Bool { source == .microphone && model.useStreaming }
    private var stateLabel: String { model.liveVoiceActive ? "Listening" : "Standing by" }
    private var stopTitle: String { isStreaming ? "Finish" : "Stop" }

    @ViewBuilder
    private var card: some View {
        RecordingCard(
            stateLabel: stateLabel,
            source: source,
            startedAt: startedAt,
            isVoiceActive: model.liveVoiceActive,
            stopTitle: stopTitle,
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
                Divider()
                LiveTranscriptView()
            } else {
                card.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { startedAt = Date() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Recording from \(source.label.lowercased()), \(stateLabel.lowercased())")
    }
}

struct RecordingCard: View {
    let stateLabel: String
    let source: AppModel.RecordSource
    let startedAt: Date
    let isVoiceActive: Bool
    let stopTitle: String
    let onStop: () -> Void

    @State private var pulse = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: DS.Spacing.large) {
            ZStack {
                Circle()
                    .fill(DS.Color.accent.opacity(0.12))
                    .frame(width: 120, height: 120)
                Image(systemName: "mic.fill")
                    .font(.system(size: 64, weight: .regular))
                    .foregroundStyle(DS.Color.accent)
                    .scaleEffect(reduceMotion ? 1.0 : (pulse ? 1.05 : 1.0))
                    .animation(
                        reduceMotion ? nil : .easeInOut(duration: 0.7).repeatForever(autoreverses: true),
                        value: pulse
                    )
            }

            VStack(spacing: DS.Spacing.small) {
                TimelineView(.periodic(from: startedAt, by: 1)) { context in
                    let elapsed = Int(context.date.timeIntervalSince(startedAt))
                    Text(String(format: "%02d:%02d", elapsed / 60, elapsed % 60))
                        .font(DS.Font.timer)
                        .foregroundStyle(DS.Color.primaryText)
                        .monospacedDigit()
                }
                HStack(spacing: 6) {
                    Circle()
                        .fill(isVoiceActive ? DS.Color.accent : DS.Color.secondaryText.opacity(0.5))
                        .frame(width: 6, height: 6)
                    Text(stateLabel)
                        .font(DS.Font.heading)
                        .foregroundStyle(DS.Color.secondaryText)
                }
                Text(source.label)
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.secondaryText.opacity(0.7))
            }

            Button(action: onStop) {
                Text(stopTitle)
                    .font(.system(.body, design: .default).weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 120, height: 36)
                    .background(
                        Capsule().fill(Color.red.opacity(0.9))
                    )
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.return)
        }
        .padding(32)
        .frame(width: 360)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(DS.Color.surfaceElevated)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(DS.Color.separator.opacity(0.6), lineWidth: 1)
        )
        .onAppear { if !reduceMotion { pulse = true } }
    }
}

struct LiveTranscriptView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: DS.Spacing.small) {
                    ForEach(model.liveSegments) { seg in
                        Text(seg.text.trimmingCharacters(in: .whitespaces))
                            .font(DS.Font.transcript)
                            .foregroundStyle(DS.Color.primaryText)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(seg.id)
                    }
                    if !model.livePartialText.isEmpty {
                        Text(model.livePartialText)
                            .font(DS.Font.transcript)
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
