import Combine
import SwiftUI
import ParolaCore
import ParolaDictation

struct DictationView: View {
    let model: AppModel
    @Bindable var controller: DictationController
    var onStop: (() -> Void)?

    @State private var startedAt: Date = Date()

    private var state: DictationCoordinator.State { controller.state }

    var body: some View {
        Group {
            switch model.dictationIndicatorStyle {
            case .nearField: nearFieldBody
            case .overlay: overlayBody
            case .notch:   notchBody
            case .minimal: minimalBody
            }
        }
        .padding(DS.Spacing.tight)
        .opacity(max(0.4, min(1.0, model.dictationHudOpacity)))
        .onChange(of: state) { _, newValue in
            if case .listening = newValue { startedAt = Date() }
        }
        .axBranch("Dictation")
    }

    private var hasPartial: Bool {
        !controller.partialText.isEmpty
    }

    private var isListening: Bool {
        if case .listening = state { return true }
        return false
    }

    private var isDownloadingModel: Bool {
        controller.modelDownloadProgress != nil
    }

    private var overlayBody: some View {
        VStack(alignment: .leading, spacing: hasPartial ? 6 : 0) {
            HStack(spacing: 12) {
                overlayIndicator
                statusLabel
                    .foregroundStyle(.white)
                if let modeName = currentModeName {
                    Text(modeName)
                        .font(DS.Font.caption)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .foregroundStyle(.white)
                        .padding(.horizontal, DS.Spacing.snug)
                        .padding(.vertical, DS.Spacing.hair)
                        .background(Capsule().fill(.white.opacity(0.18)))
                }
                Spacer(minLength: 0)
                timer
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .foregroundStyle(.white.opacity(0.7))
                stopButton
            }
            .frame(height: 32)
            if hasPartial {
                runningTranscript
            }
        }
        .padding(.horizontal, DS.Spacing.medium)
        .padding(.vertical, DS.Spacing.regular)
        .frame(width: hasPartial ? 344 : (isListening || isDownloadingModel ? 324 : 256), alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Self.overlayRadius, style: .continuous)
                .fill(Color.black.opacity(0.85))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Self.overlayRadius, style: .continuous)
                .stroke(.white.opacity(0.08), lineWidth: 1)
        )
    }

    private var runningTranscript: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                Text(controller.recentDictation)
                    .font(DS.Font.body)
                    .foregroundStyle(.white.opacity(0.9))
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .id(transcriptTailAnchor)
            }
            .frame(height: 84)
            .onChange(of: controller.recentDictation) {
                withAnimation(.easeOut(duration: 0.15)) {
                    proxy.scrollTo(transcriptTailAnchor, anchor: .bottom)
                }
            }
        }
    }

    private let transcriptTailAnchor = "dictation.transcript.tail"

    private static let overlayRadius: CGFloat = 22
    private static let barRadius: CGFloat = 14
    private static let notchInset: CGFloat = 14

    private var notchBody: some View {
        HStack(spacing: 10) {
            indicator
                .frame(width: 22, height: 16)
            Text(notchLabel)
                .font(DS.Font.bodyStrong)
                .foregroundStyle(.white.opacity(0.9))
                .lineLimit(1)
            Spacer(minLength: 0)
            timer
                .font(DS.Font.mono)
                .foregroundStyle(.white.opacity(0.65))
            stopButton
        }
        .padding(.horizontal, Self.notchInset)
        .padding(.vertical, DS.Spacing.snug)
        .frame(width: hasPartial ? 360 : 240, height: 28, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Self.barRadius, style: .continuous)
                .fill(Color.black.opacity(0.9))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Self.barRadius, style: .continuous)
                .stroke(.white.opacity(0.05), lineWidth: 1)
        )
    }

    private var minimalBody: some View {
        ZStack {
            Circle()
                .fill(Color.black.opacity(0.85))
                .overlay(
                    Circle()
                        .stroke(.white.opacity(0.08), lineWidth: 1)
                )
            indicator
                .frame(width: 18, height: 14)
                .scaleEffect(0.85)
        }
        .frame(width: 36, height: 36)
    }

    private var hasFailureMessage: Bool {
        if case .failed(let message) = state { return !message.isEmpty }
        return false
    }

    private var nearFieldLabel: String {
        if case .failed(let message) = state, !message.isEmpty { return message }
        return label
    }

    private var nearFieldBody: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                indicator
                    .frame(width: 24, height: 16)
                Text(nearFieldLabel)
                    .font(DS.Font.caption)
                    .foregroundStyle(.white.opacity(0.9))
                    .lineLimit(hasFailureMessage ? 2 : 1)
                Spacer(minLength: 0)
                stopButton
            }
            if hasPartial {
                Text(controller.recentDictation)
                    .font(DS.Font.caption)
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(2)
                    .truncationMode(.head)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, DS.Spacing.regular)
        .padding(.vertical, DS.Spacing.small)
        .frame(width: hasPartial || hasFailureMessage ? 352 : 192, height: hasPartial || hasFailureMessage ? 88 : 36, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Self.barRadius, style: .continuous)
                .fill(Color.black.opacity(0.88))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Self.barRadius, style: .continuous)
                .stroke(.white.opacity(0.08), lineWidth: 1)
        )
    }

    private var notchLabel: String {
        guard hasPartial else { return label }
        let lastLine = controller.recentDictation
            .split(separator: "\n", omittingEmptySubsequences: true)
            .last
        return lastLine.map(String.init) ?? controller.recentDictation
    }

    @ViewBuilder
    private var indicator: some View {
        switch state {
        case .idle:
            if isDownloadingModel {
                SpinningRing().frame(width: 14, height: 14)
            } else {
                Circle().fill(Color.white.opacity(0.45)).frame(width: 14, height: 14)
            }
        case .listening:
            LiveWaveformBars(levelSubject: controller.audioLevel)
        case .transcribing:
            SpinningRing().frame(width: 14, height: 14)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(DS.Font.heading)
                .foregroundStyle(DS.Palette.warning)
        }
    }

    @ViewBuilder
    private var overlayIndicator: some View {
        switch state {
        case .listening:
            LiveWaveformHistory(levelSubject: controller.audioLevel, capacity: 18, maxHeight: 20)
                .frame(height: 22)
                .fixedSize(horizontal: true, vertical: true)
        default:
            indicator
                .frame(width: 28, height: 20)
        }
    }

    @ViewBuilder
    private var statusLabel: some View {
        Text(label)
            .font(DS.Font.bodyStrong)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
    }

    @ViewBuilder
    private var stopButton: some View {
        if let onStop, case .listening = state {
            Button(action: onStop) {
                ZStack {
                    Circle().fill(Color.white.opacity(0.14))
                    Image(systemName: "stop.fill")
                        .font(DS.Font.caption)
                        .foregroundStyle(.white)
                }
                .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .help("Stop dictation")
            .accessibilityLabel("Stop dictation")
            .axLeaf("HUD.Button.Stop")
        }
    }

    @ViewBuilder
    private var timer: some View {
        switch state {
        case .listening, .transcribing:
            TimelineView(.periodic(from: startedAt, by: 1)) { context in
                let elapsed = Int(context.date.timeIntervalSince(startedAt))
                Text(String(format: "%02d:%02d", elapsed / 60, elapsed % 60))
                    .font(DS.Font.mono)
            }
        default:
            Text("00:00")
                .font(DS.Font.mono)
                .opacity(0)
        }
    }

    private var currentModeName: String? {
        AppModel.dictationCleanupModeName(for: model.dictationCleanupPromptID)
    }

    private var label: String {
        if let progress = controller.modelDownloadProgress {
            return String(localized: "Downloading model… \(AppFormat.percent(progress))")
        }
        switch state {
        case .idle: return String(localized: "Ready")
        case .listening: return String(localized: "Listening")
        case .transcribing: return String(localized: "Transcribing")
        case .failed: return String(localized: "Failed")
        }
    }
}

// Audio levels arrive far faster than a display needs; throttle to ~22 fps so the live waveform
// stays smooth instead of flooding the main thread with redraws during speech.

private struct LiveWaveformBars: View {
    let levelSubject: CurrentValueSubject<Float, Never>
    @State private var level: Float = 0
    var body: some View {
        WaveformBars(level: level)
            .onReceive(levelSubject.throttle(for: .milliseconds(45), scheduler: DispatchQueue.main, latest: true)) { level = $0 }
    }
}

private struct LiveWaveformHistory: View {
    let levelSubject: CurrentValueSubject<Float, Never>
    let capacity: Int
    let maxHeight: CGFloat
    @State private var level: Float = 0
    var body: some View {
        WaveformHistory(level: level, capacity: capacity, maxHeight: maxHeight)
            .onReceive(levelSubject.throttle(for: .milliseconds(45), scheduler: DispatchQueue.main, latest: true)) { level = $0 }
    }
}

