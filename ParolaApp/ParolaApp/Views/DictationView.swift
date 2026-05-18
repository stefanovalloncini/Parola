import Combine
import SwiftUI
import ParolaCore

struct DictationView: View {
    let state: DictationCoordinator.State
    @ObservedObject var model: AppModel
    @ObservedObject var controller: DictationController
    var onStop: (() -> Void)?

    @State private var startedAt: Date = Date()

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
                        .font(.system(size: 10, weight: .semibold))
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
                Text(controller.partialText)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .frame(width: hasPartial ? 320 : 256, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color.black.opacity(0.85))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(.white.opacity(0.08), lineWidth: 1)
        )
        .animation(.easeOut(duration: 0.18), value: hasPartial)
    }

    private var notchBody: some View {
        HStack(spacing: 10) {
            indicator
                .frame(width: 22, height: 16)
            Text(notchLabel)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.9))
                .lineLimit(1)
            Spacer(minLength: 0)
            timer
                .font(.system(size: 11, design: .monospaced))
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
        .animation(.easeOut(duration: 0.18), value: hasPartial)
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
        if hasPartial { return controller.partialText }
        return label
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
                .font(.system(size: 16))
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
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white)
                }
                .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .help("Stop dictation")
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

private struct LiveWaveformBars: View {
    let levelSubject: CurrentValueSubject<Float, Never>
    @State private var level: Float = 0
    var body: some View {
        WaveformBars(level: level)
            .onReceive(levelSubject) { level = $0 }
    }
}

private struct LiveWaveformHistory: View {
    let levelSubject: CurrentValueSubject<Float, Never>
    let capacity: Int
    let maxHeight: CGFloat
    @State private var level: Float = 0
    var body: some View {
        WaveformHistory(level: level, capacity: capacity, maxHeight: maxHeight)
            .onReceive(levelSubject) { level = $0 }
    }
}

private struct WaveformBars: View {
    let level: Float

    private static let barCount = 5
    private static let phaseOffsets: [Float] = [0.85, 1.05, 1.0, 0.95, 0.8]
    private static let idleHeight: CGFloat = 3
    private static let maxHeight: CGFloat = 18
    private static let barWidth: CGFloat = 3
    private static let spacing: CGFloat = 2

    var body: some View {
        HStack(alignment: .center, spacing: Self.spacing) {
            ForEach(0..<Self.barCount, id: \.self) { index in
                Capsule(style: .continuous)
                    .fill(Color.white)
                    .frame(width: Self.barWidth, height: barHeight(at: index))
            }
        }
        .frame(height: Self.maxHeight)
    }

    private func barHeight(at index: Int) -> CGFloat {
        if level <= 0.02 { return Self.idleHeight }
        let shaped = pow(level, 0.6)
        let offset = Self.phaseOffsets[index % Self.phaseOffsets.count]
        let scaled = min(1, max(0, CGFloat(shaped * offset)))
        return Self.idleHeight + (Self.maxHeight - Self.idleHeight) * scaled
    }
}

private struct SpinningRing: View {
    @State private var rotate = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Circle()
            .trim(from: 0, to: 0.7)
            .stroke(Color.white.opacity(0.9), style: StrokeStyle(lineWidth: 2, lineCap: .round))
            .rotationEffect(.degrees(rotate ? 360 : 0))
            .animation(
                reduceMotion ? nil : .linear(duration: 0.9).repeatForever(autoreverses: false),
                value: rotate
            )
            .onAppear { if !reduceMotion { rotate = true } }
    }
}
