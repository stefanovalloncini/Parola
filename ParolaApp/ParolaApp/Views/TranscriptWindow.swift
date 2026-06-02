import AppKit
import SwiftUI
import ParolaCore

@MainActor
final class TranscriptWindowController {
    static let shared = TranscriptWindowController()

    private var windows: [NSWindow] = []
    private let delegate = WindowDelegate()

    func open(transcript: Transcript, title: String) {
        delegate.controller = self
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = title.isEmpty ? "Transcript" : title
        window.isReleasedWhenClosed = false
        window.center()
        window.contentView = NSHostingView(rootView: TranscriptWindowView(transcript: transcript, title: title))
        window.delegate = delegate
        windows.append(window)
        window.makeKeyAndOrderFront(nil)
    }

    fileprivate func remove(_ window: NSWindow) {
        windows.removeAll { $0 === window }
    }

    @MainActor
    private final class WindowDelegate: NSObject, NSWindowDelegate {
        weak var controller: TranscriptWindowController?
        func windowWillClose(_ notification: Notification) {
            if let window = notification.object as? NSWindow {
                controller?.remove(window)
            }
        }
    }
}

struct TranscriptWindowView: View {
    let transcript: Transcript
    let title: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(transcript.segments) { segment in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 8) {
                                Text(Timecode.format(segment.start))
                                    .font(DS.Font.subheadlineMono)
                                    .foregroundStyle(.secondary)
                                if let speaker = segment.speaker {
                                    Text(speaker)
                                        .font(DS.Font.subheadlineEmphasized)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Text(segment.text.trimmingCharacters(in: .whitespaces))
                                .font(DS.Font.body)
                                .textSelection(.enabled)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(20)
            }
        }
    }

    private var header: some View {
        HStack {
            Text(title.isEmpty ? "Transcript" : title)
                .font(.title3.weight(.semibold))
            Spacer()
            Text("\(transcript.segments.count) segments")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }
}
