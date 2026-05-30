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
            case .overlay: overlayBody
            case .notch:   notchBody
            case .minimal: minimalBody
            }
        }
        .padding(4)
        .opacity(max(0.4, min(1.0, model.dictationHudOpacity)))
        .onChange(of: state) { _, newValue in
            if case .listening = newValue { startedAt = Date() }
        }
        .axBranch("Dictation")
    }

    private var hasPartial: Bool {
        !controller.partialText.isEmpty
    }

    private var overlayBody: some View {
        VStack(alignment: .leading, spacing: hasPartial ? 6 : 0) {
            HStack(spacing: 12) {
                overlayIndicator
                statusLabel
                    .foregroundStyle(.white)
                if let modeName = currentModeName {
                    Text(modeName)
                        .font(DS.Font.caption2Emphasized)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(.white.opacity(0.18)))
                }
                Spacer(minLength: 0)
                timer
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
        .frame(width: hasPartial ? 344 : 256, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color.black.opacity(0.85))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
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

    private var notchBody: some View {
        HStack(spacing: 10) {
            indicator
                .frame(width: 22, height: 16)
            Text(notchLabel)
                .font(DS.Font.subheadlineMedium)
                .foregroundStyle(.white.opacity(0.9))
                .lineLimit(1)
            Spacer(minLength: 0)
            timer
                .font(DS.Font.subheadlineMono)
                .foregroundStyle(.white.opacity(0.65))
            stopButton
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .frame(width: hasPartial ? 360 : 240, height: 28, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.black.opacity(0.9))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
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
            Circle().fill(Color.gray.opacity(0.6)).frame(width: 14, height: 14)
        case .listening:
            LiveWaveformBars(levelSubject: controller.audioLevel)
        case .transcribing:
            SpinningRing().frame(width: 14, height: 14)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(DS.Font.title3Regular)
                .foregroundStyle(.orange)
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
            .font(.subheadline.weight(.semibold))
    }

    @ViewBuilder
    private var stopButton: some View {
        if let onStop, case .listening = state {
            Button(action: onStop) {
                ZStack {
                    Circle().fill(Color.white.opacity(0.14))
                    Image(systemName: "stop.fill")
                        .font(DS.Font.caption2Bold)
                        .foregroundStyle(.white)
                }
                .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .help("Stop dictation")
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
                    .font(.system(.subheadline, design: .monospaced))
                    .monospacedDigit()
            }
        default:
            Text("00:00")
                .font(.system(.subheadline, design: .monospaced))
                .monospacedDigit()
                .opacity(0)
        }
    }

    private var currentModeName: String? {
        let id = model.dictationCleanupPromptID
        if id.isEmpty {
            return DictationModePreset.builtIns.first { $0.promptID == nil }?.name
        }
        guard let uuid = UUID(uuidString: id) else { return nil }
        if let preset = DictationModePreset.builtIns.first(where: { $0.promptID == uuid }) {
            return preset.name
        }
        return Prompt.builtIns.first(where: { $0.id == uuid })?.name
    }

    private var label: String {
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

