import SwiftUI
import ParolaCore

struct DictationView: View {
    let state: DictationCoordinator.State
    @ObservedObject var model: AppModel
    var onStop: (() -> Void)?

    @State private var startedAt: Date = Date()

    var body: some View {
        VStack(alignment: .leading, spacing: hasPartial ? 6 : 0) {
            HStack(spacing: 12) {
                indicator
                    .frame(width: 28, height: 20)
                statusLabel
                    .foregroundStyle(.white)
                Spacer(minLength: 0)
                timer
                    .foregroundStyle(.white.opacity(0.7))
                stopButton
            }
            .frame(height: 32)
            if hasPartial {
                Text(model.dictationPartialText)
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
        .padding(4)
        .onChange(of: state) { _, newValue in
            if case .listening = newValue { startedAt = Date() }
        }
    }

    private var hasPartial: Bool {
        !model.dictationPartialText.isEmpty
    }

    @ViewBuilder
    private var indicator: some View {
        switch state {
        case .idle:
            Circle().fill(Color.gray.opacity(0.6)).frame(width: 14, height: 14)
        case .listening:
            WaveformBars(level: model.dictationAudioLevel)
        case .transcribing:
            SpinningRing().frame(width: 14, height: 14)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 16))
                .foregroundStyle(.orange)
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

    private var label: String {
        switch state {
        case .idle: return "Ready"
        case .listening: return "Listening"
        case .transcribing: return "Transcribing"
        case .failed: return "Failed"
        }
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

    @State private var idlePulse = false

    var body: some View {
        HStack(alignment: .center, spacing: Self.spacing) {
            ForEach(0..<Self.barCount, id: \.self) { index in
                Capsule(style: .continuous)
                    .fill(Color.white)
                    .frame(width: Self.barWidth, height: barHeight(at: index))
                    .animation(.easeOut(duration: 0.08), value: level)
            }
        }
        .frame(height: Self.maxHeight)
        .onAppear { idlePulse = true }
        .animation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true), value: idlePulse)
    }

    private func barHeight(at index: Int) -> CGFloat {
        if level <= 0.02 {
            return idlePulse ? Self.idleHeight + 1 : Self.idleHeight
        }
        let shaped = pow(level, 0.6)
        let offset = Self.phaseOffsets[index % Self.phaseOffsets.count]
        let scaled = min(1, max(0, CGFloat(shaped * offset)))
        return Self.idleHeight + (Self.maxHeight - Self.idleHeight) * scaled
    }
}

private struct SpinningRing: View {
    @State private var rotate = false
    var body: some View {
        Circle()
            .trim(from: 0, to: 0.7)
            .stroke(Color.white.opacity(0.9), style: StrokeStyle(lineWidth: 2, lineCap: .round))
            .rotationEffect(.degrees(rotate ? 360 : 0))
            .animation(.linear(duration: 0.9).repeatForever(autoreverses: false), value: rotate)
            .onAppear { rotate = true }
    }
}
