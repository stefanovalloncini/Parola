import SwiftUI
import AVKit
import AppKit

struct MiniPlayerWindow: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 8) {
            currentSegmentText
            controls
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(minWidth: 320, idealWidth: 360, maxWidth: 520)
        .background(MiniPlayerWindowConfigurator())
    }

    private var currentSegmentText: some View {
        let text: String = {
            guard let transcript = model.transcript,
                  let id = model.currentSegmentID,
                  let seg = transcript.segments.first(where: { $0.id == id })
            else {
                return model.transcript == nil ? "No transcript loaded" : "—"
            }
            return seg.text.trimmingCharacters(in: .whitespacesAndNewlines)
        }()
        return Text(text)
            .font(.system(size: 13, weight: .regular))
            .foregroundStyle(.primary)
            .lineLimit(2)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var controls: some View {
        HStack(spacing: 10) {
            Button(action: previous) {
                Image(systemName: "backward.fill")
            }
            .buttonStyle(.borderless)
            .disabled(model.transcript == nil)

            Button(action: togglePlayPause) {
                Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(DS.Color.accent))
            }
            .buttonStyle(.plain)
            .disabled(model.player == nil)

            Button(action: next) {
                Image(systemName: "forward.fill")
            }
            .buttonStyle(.borderless)
            .disabled(model.transcript == nil)

            Spacer()

            Text(timeLabel)
                .font(.system(size: 11, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }

    private var timeLabel: String {
        let cur = Int(max(0, model.currentTimeSeconds.rounded()))
        let total = Int(max(0, (model.transcript?.durationSeconds ?? 0).rounded()))
        return "\(format(cur)) / \(format(total))"
    }

    private func format(_ s: Int) -> String {
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%02d:%02d", m, sec)
    }

    private func togglePlayPause() {
        guard let player = model.player else { return }
        if player.timeControlStatus == .playing { player.pause() } else { player.play() }
    }

    private func previous() {
        guard let transcript = model.transcript, !transcript.segments.isEmpty else { return }
        if let current = model.currentSegmentID,
           let idx = transcript.segments.firstIndex(where: { $0.id == current }),
           idx > 0 {
            model.seek(to: transcript.segments[idx - 1])
        } else if let first = transcript.segments.first {
            model.seek(to: first)
        }
    }

    private func next() {
        guard let transcript = model.transcript, !transcript.segments.isEmpty else { return }
        if let current = model.currentSegmentID,
           let idx = transcript.segments.firstIndex(where: { $0.id == current }),
           idx + 1 < transcript.segments.count {
            model.seek(to: transcript.segments[idx + 1])
        } else if let first = transcript.segments.first {
            model.seek(to: first)
        }
    }
}

private struct MiniPlayerWindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        Task { @MainActor in
            guard let window = view.window else { return }
            window.level = .floating
            window.title = "Parola Mini Player"
            window.collectionBehavior.insert(.canJoinAllSpaces)
        }
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}
