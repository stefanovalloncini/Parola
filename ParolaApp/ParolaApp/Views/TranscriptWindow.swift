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
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(transcript.segments) { segment in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 8) {
                                Text(Timecode.format(segment.start))
                                    .font(DS.Font.subheadlineMono)
                                    .foregroundStyle(DS.Color.secondaryText)
                                if let speaker = SegmentCard.speakerLabel(for: segment.speaker) {
                                    Text(speaker)
                                        .font(DS.Font.subheadlineEmphasized)
                                        .foregroundStyle(DS.Color.secondaryText)
                                }
                            }
                            Text(segment.text.trimmingCharacters(in: .whitespaces))
                                .font(DS.Font.body)
                                .textSelection(.enabled)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(DS.Spacing.large)
            }
        }
    }

    private var header: some View {
        PageHeader(
            title: title.isEmpty ? "Transcript" : title,
            count: SegmentCount.label(transcript.segments.count),
            trailing: { EmptyView() }
        )
    }
}
