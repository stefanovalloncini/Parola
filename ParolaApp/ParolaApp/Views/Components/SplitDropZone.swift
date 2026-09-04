import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// While a drag is over the window, the whole window becomes the two things a file can be:
/// transcribed now, or parked in the queue. Attach it to the window root so the sidebar
/// answers a drag too.
struct SplitDropZone: ViewModifier {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var height: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
            .overlay {
                ZStack {
                    if model.dropZonePlan != .none {
                        SplitDropOverlay(plan: model.dropZonePlan, highlight: model.dropHighlight)
                            .transition(.opacity)
                    }
                }
                .allowsHitTesting(false)
                .animation(transition, value: model.dropDragPayload)
                .animation(transition, value: model.dropHighlight)
            }
            .onDrop(of: [.fileURL, .url], delegate: SplitDropDelegate(model: model, height: height))
    }

    private var transition: Animation? {
        reduceMotion ? nil : .easeOut(duration: 0.12)
    }
}

private struct SplitDropDelegate: DropDelegate {
    let model: AppModel
    let height: CGFloat

    func validateDrop(info: DropInfo) -> Bool {
        if model.dropDragPayload == nil {
            model.dropDragPayload = DroppedFiles.classify(Self.draggedURLs(), folders: .shallow).kind
        }
        guard model.dropZonePlan != .none else {
            model.dropDragPayload = nil
            return false
        }
        return true
    }

    func dropEntered(info: DropInfo) {
        model.dropHighlight = half(at: info.location)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        let target = half(at: info.location)
        if model.dropHighlight != target { model.dropHighlight = target }
        return DropProposal(operation: .copy)
    }

    func dropExited(info: DropInfo) {
        model.dropDragPayload = nil
        model.dropHighlight = nil
    }

    func performDrop(info: DropInfo) -> Bool {
        let target = half(at: info.location)
        model.dropDragPayload = nil
        model.dropHighlight = nil
        let urls = Self.draggedURLs()
        guard !urls.isEmpty else { return false }
        model.drop(urls, on: target)
        return true
    }

    private func half(at location: CGPoint) -> AppModel.DropHalf {
        switch model.dropZonePlan {
        case .split:
            return location.y < height / 2 ? .now : .queue
        case .queueOnly:
            return .queue
        default:
            return .now
        }
    }

    /// The drag pasteboard is readable straight through, which keeps the payload synchronous —
    /// item providers only hand a URL back asynchronously, long after the zones must be drawn.
    private static func draggedURLs() -> [URL] {
        let pasteboard = NSPasteboard(name: .drag)
        let objects = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: false]
        )
        return (objects as? [URL]) ?? []
    }
}

private struct SplitDropOverlay: View {
    let plan: DroppedFiles.ZonePlan
    let highlight: AppModel.DropHalf?

    var body: some View {
        ZStack {
            DS.Palette.canvas.opacity(0.96)
                .ignoresSafeArea()
            VStack(spacing: DS.Spacing.small) {
                header
                zones
            }
            .padding(DS.Spacing.medium)
        }
        .axBranch("SplitDrop")
    }

    private var header: some View {
        HStack(spacing: DS.Spacing.regular) {
            if let countLabel {
                Text(countLabel)
                    .font(DS.Font.subheadlineMedium)
                    .foregroundStyle(DS.Color.secondaryText)
            }
            if showsIntakeState {
                IntakeStateChips()
            }
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var zones: some View {
        switch plan {
        case .split:
            VStack(spacing: DS.Spacing.small) {
                transcribeZone
                queueZone
            }
        case .transcribeOnly:
            DropZonePanel(
                systemImage: "waveform",
                title: "Drop to Transcribe",
                subtitle: "Starts right away",
                isHot: highlight == .now
            )
            .axLeaf("SplitDrop.Zone.Now")
        case .queueOnly:
            queueZone
        case .importSubtitles:
            DropZonePanel(
                systemImage: "captions.bubble",
                title: "Import Subtitles",
                subtitle: "Open them as a transcript",
                isHot: highlight == .now
            )
            .axLeaf("SplitDrop.Zone.Now")
        case .openProjects:
            DropZonePanel(
                systemImage: "doc.richtext",
                title: "Open Project",
                subtitle: "Load the saved transcript",
                isHot: highlight == .now
            )
            .axLeaf("SplitDrop.Zone.Now")
        case .transcribeLink:
            DropZonePanel(
                systemImage: "link",
                title: "Transcribe Link",
                subtitle: "Downloads the audio first",
                isHot: highlight == .now
            )
            .axLeaf("SplitDrop.Zone.Now")
        case .none:
            EmptyView()
        }
    }

    private var transcribeZone: some View {
        DropZonePanel(
            systemImage: "waveform",
            title: "Transcribe Now",
            subtitle: "Starts right away",
            isHot: highlight == .now
        )
        .axLeaf("SplitDrop.Zone.Now")
    }

    private var queueZone: some View {
        DropZonePanel(
            systemImage: "square.stack.3d.up",
            title: "Add to Queue",
            subtitle: queueSubtitle,
            isHot: highlight == .queue
        )
        .axLeaf("SplitDrop.Zone.Queue")
    }

    private var queueSubtitle: LocalizedStringKey {
        if case .queueOnly = plan { return "Starts when the current job finishes" }
        return "Transcribe later"
    }

    private var showsIntakeState: Bool {
        switch plan {
        case .split, .transcribeOnly, .queueOnly, .transcribeLink: return true
        case .importSubtitles, .openProjects, .none: return false
        }
    }

    private var count: Int? {
        switch plan {
        case .split(let n), .transcribeOnly(let n), .queueOnly(let n),
             .importSubtitles(let n), .openProjects(let n):
            return n
        case .transcribeLink, .none:
            return nil
        }
    }

    private var countLabel: LocalizedStringKey? {
        if case .transcribeLink = plan { return "1 link" }
        guard let count else { return nil }
        return count == 1 ? "1 file" : "\(count) files"
    }
}

private struct DropZonePanel: View {
    let systemImage: String
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey
    let isHot: Bool

    @ScaledMetric(relativeTo: .title) private var iconSize: CGFloat = 30

    var body: some View {
        VStack(spacing: DS.Spacing.small) {
            Image(systemName: systemImage)
                .font(.system(size: iconSize, weight: .regular))
                .foregroundStyle(isHot ? DS.Color.onAccent : DS.Color.accent)
            Text(title)
                .font(DS.Font.heading)
                .foregroundStyle(isHot ? DS.Color.onAccent : DS.Color.primaryText)
            Text(subtitle)
                .font(DS.Font.body)
                .foregroundStyle(isHot ? DS.Color.onAccent.opacity(0.8) : DS.Color.secondaryText)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.regular, style: .continuous)
                .fill(isHot ? DS.Color.accent : DS.Color.surfaceElevated)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.regular, style: .continuous)
                .strokeBorder(DS.Color.accent, style: StrokeStyle(lineWidth: 2, dash: isHot ? [] : [6, 6]))
        )
    }
}
