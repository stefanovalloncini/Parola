import SwiftUI
import ParolaCore

struct DictationView: View {
    let state: DictationCoordinator.State

    @State private var startedAt: Date = Date()

    var body: some View {
        HStack(spacing: 14) {
            indicator
                .frame(width: 14, height: 14)
            statusLabel
                .foregroundStyle(.white)
            Spacer(minLength: 0)
            timer
                .foregroundStyle(.white.opacity(0.7))
        }
        .padding(.horizontal, 18)
        .frame(width: 220, height: 56)
        .background(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(Color.black.opacity(0.85))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .stroke(.white.opacity(0.08), lineWidth: 1)
        )
        .padding(4)
        .onChange(of: state) { _, newValue in
            if case .listening = newValue { startedAt = Date() }
        }
    }

    @ViewBuilder
    private var indicator: some View {
        switch state {
        case .idle:
            Circle().fill(Color.gray.opacity(0.6))
        case .listening:
            ListeningDot()
        case .transcribing:
            SpinningRing()
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 14))
                .foregroundStyle(.orange)
        }
    }

    @ViewBuilder
    private var statusLabel: some View {
        Text(label)
            .font(.subheadline.weight(.semibold))
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

private struct ListeningDot: View {
    @State private var pulse = false
    var body: some View {
        Circle()
            .fill(Color.red)
            .scaleEffect(pulse ? 1.0 : 0.7)
            .opacity(pulse ? 1.0 : 0.5)
            .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: pulse)
            .onAppear { pulse = true }
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
