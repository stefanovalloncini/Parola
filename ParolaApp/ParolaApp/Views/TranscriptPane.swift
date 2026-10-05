import SwiftUI
import AVKit
import ParolaCore

struct PlayerSurface: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .none
        view.showsFullScreenToggleButton = false
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        if nsView.player !== player {
            nsView.player = player
        }
    }
}

struct AssumedLanguageNote: View {
    let text: String

    var body: some View {
        Label {
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
                .multilineTextAlignment(.leading)
        } icon: {
            Image(systemName: "globe.badge.chevron.backward")
        }
        .font(DS.Font.secondary)
        .foregroundStyle(DS.Color.secondaryText)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, DS.Spacing.regular)
        .padding(.vertical, DS.Spacing.small)
        .axLeaf("Transcript.Label.AssumedLanguage")
    }
}

enum TranscriptDisplayMode: String, CaseIterable, Identifiable {
    case transcript
    case segments
    var id: String { rawValue }
}

enum InspectorMode: String, CaseIterable, Identifiable {
    case format
    case info
    var id: String { rawValue }

    /// "actions" was a third tab whose sections now live in Info; a value stored by that build still has to land somewhere.
    init(stored raw: String) {
        switch raw {
        case InspectorMode.info.rawValue, "actions": self = .info
        default: self = .format
        }
    }
}

struct TranscriptPane: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.arrivesFromStage) private var arrivesFromStage
    @Environment(AppModel.self) private var model
    @AppStorage(InspectorVisibility.preferenceKey, store: DefaultsStore.current) private var inspectorVisible: Bool = true
    @AppStorage(InspectorVisibility.modeKey, store: DefaultsStore.current) private var inspectorModeRaw: String = InspectorMode.format.rawValue
    // Persisted: the pane is rebuilt on every phase and route change, and the ask has to outlive that.
    @AppStorage(InspectorVisibility.forcedAtNarrowWidthKey, store: DefaultsStore.current)
    private var inspectorForcedAtNarrowWidth = false
    @State private var paneIsNarrow = false

    private var displayMode: TranscriptDisplayMode {
        model.transcriptDisplayMode
    }

    var body: some View {
        VStack(spacing: 0) {
            TranscriptHeaderBar(title: model.transcriptHeaderTitle)
            Divider()

            if model.transcriptFindBarShows {
                FindBar()
            }

            // Not an HSplitView: it lays its panes out at their combined minimum and overflows a narrow window.
            HStack(spacing: 0) {
                transcriptColumn
                    .frame(minWidth: MainWindowLayout.transcriptMinWidth, maxWidth: .infinity)

                if showsInspector {
                    Divider()
                    TranscriptInspector(
                        mode: inspectorModeBinding,
                        inspectorVisible: inspectorVisibleBinding
                    )
                    .frame(width: MainWindowLayout.inspectorWidth)
                }
            }
            // Measured on the whole pane, not the reading column, so hiding the inspector can't re-widen it into a loop.
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.width
            } action: { width in
                applyPaneWidth(width)
            }
        }
        .task { model.refreshAIAvailability() }
        .axBranch("Transcript")
    }

    private var transcriptColumn: some View {
        VStack(spacing: 0) {
            if let notice = model.assumedLanguageNotice {
                AssumedLanguageNote(text: notice)
                Divider()
            }

            transcriptBody
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .arrivesAfterTheStage(model.routeLandsTake && arrivesFromStage)

            // In the column's flow, not over it: a toast on top of the media bar would cover the
            // transport for as long as it is up.
            if let notice = model.visibleDeliveryNotice {
                DeliveryToast(notice: notice)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            if model.hasVideo, let player = model.player {
                Divider()
                PlayerSurface(player: player)
                    .frame(height: 200)
                    .background(Color.black)
            }

            if model.player != nil {
                Divider()
                MediaBar()
                    .stageLandingDestination(.band)
            }
        }
        .animation(reduceMotion ? nil : .smooth(duration: 0.25), value: model.visibleDeliveryNotice)
    }

    @ViewBuilder
    private var transcriptBody: some View {
        switch model.transcriptPaneMode {
        case .summary:
            SummaryPane()
        case .chat:
            ChatPane()
        case .transcript:
            if model.transcriptIsEmpty {
                EmptyTranscriptPane()
            } else {
                switch displayMode {
                case .segments:
                    SegmentsScroll()
                case .transcript:
                    ContinuousTranscriptView()
                }
            }
        }
    }

    private var showsInspector: Bool {
        InspectorVisibility.isVisible(
            preference: inspectorVisible,
            forcedAtNarrowWidth: inspectorForcedAtNarrowWidth,
            isNarrow: paneIsNarrow
        )
    }

    private var inspectorVisibleBinding: Binding<Bool> {
        Binding(
            get: { showsInspector },
            set: { shown in
                if paneIsNarrow {
                    inspectorForcedAtNarrowWidth = shown
                } else {
                    inspectorVisible = shown
                }
            }
        )
    }

    private func applyPaneWidth(_ width: CGFloat) {
        let narrow = width < MainWindowLayout.inspectorCollapseWidth
        if paneIsNarrow != narrow { paneIsNarrow = narrow }
        if model.transcriptPaneIsNarrow != narrow { model.transcriptPaneIsNarrow = narrow }
        if !narrow, inspectorForcedAtNarrowWidth { inspectorForcedAtNarrowWidth = false }
    }

    private var inspectorModeBinding: Binding<InspectorMode> {
        Binding(
            get: { InspectorMode(stored: inspectorModeRaw) },
            set: { inspectorModeRaw = $0.rawValue }
        )
    }
}
