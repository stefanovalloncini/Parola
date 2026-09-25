import SwiftUI
import AVKit
import AppKit
import ParolaCore

struct MiniPlayerWindow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 8) {
            currentSegmentText
            controls
        }
        .id(model.themeRevision)
        .padding(.horizontal, DS.Spacing.regular)
        .padding(.vertical, DS.Spacing.small)
        .frame(minWidth: 320, idealWidth: 360, maxWidth: 520)
        .background(MiniPlayerWindowConfigurator())
        .axBranch("MiniPlayer")
    }

    private var currentSegmentText: some View {
        let text: String = {
            guard let transcript = model.transcript,
                  let id = model.currentSegmentID,
                  let seg = Self.segment(withID: id, in: transcript.segments, hint: model.currentSegmentIndex)
            else {
                return model.transcript == nil ? "No transcript loaded" : "—"
            }
            return seg.text.trimmingCharacters(in: .whitespacesAndNewlines)
        }()
        return Text(text)
            .font(DS.Font.body)
            .foregroundStyle(.primary)
            .lineLimit(2)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    static func segment(withID id: TranscriptSegment.ID, in segments: [TranscriptSegment], hint: Int?) -> TranscriptSegment? {
        if let hint, segments.indices.contains(hint), segments[hint].id == id {
            return segments[hint]
        }
        return segments.first(where: { $0.id == id })
    }

    private var controls: some View {
        HStack(spacing: 10) {
            Button(action: previous) {
                Image(systemName: "backward.fill")
            }
            .buttonStyle(.borderless)
            .disabled(model.transcript == nil)
            .help("Previous segment")
            .accessibilityLabel("Previous segment")
            .axLeaf("MiniPlayer.Button.Previous")

            Button { model.togglePlayPause() } label: {
                Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                    .font(DS.Font.heading)
                    .foregroundStyle(DS.Color.onAccent)
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(DS.Color.accent))
            }
            .buttonStyle(.plain)
            .disabled(model.player == nil)
            .help(model.isPlaying ? "Pause" : "Play")
            .accessibilityLabel(model.isPlaying ? "Pause" : "Play")
            .axLeaf("MiniPlayer.Button.PlayPause")

            Button(action: next) {
                Image(systemName: "forward.fill")
            }
            .buttonStyle(.borderless)
            .disabled(model.transcript == nil)
            .help("Next segment")
            .accessibilityLabel("Next segment")
            .axLeaf("MiniPlayer.Button.Next")

            Spacer()

            MiniPlayerTimeLabel()
        }
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

private struct MiniPlayerTimeLabel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Text(PlaybackProgressView.timeLabel(
            current: model.currentTimeSeconds,
            total: model.transcript?.durationSeconds ?? 0
        ))
        .font(DS.Font.mono)
        .foregroundStyle(DS.Color.secondaryText)
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
