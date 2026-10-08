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

struct TranscriptPane: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.arrivesFromStage) private var arrivesFromStage
    @Environment(AppModel.self) private var model
    @AppStorage(InspectorVisibility.preferenceKey, store: DefaultsStore.current) private var inspectorVisible: Bool = true
    // Persisted: the pane is rebuilt on every phase and route change, and the ask has to outlive that.
    @AppStorage(InspectorVisibility.forcedAtNarrowWidthKey, store: DefaultsStore.current)
    private var inspectorForcedAtNarrowWidth = false
    @State private var paneIsNarrow = false

    private var displayMode: TranscriptDisplayMode {
        model.transcriptDisplayMode
    }

    var body: some View {
        VStack(spacing: 0) {
            if model.transcriptFindBarShows {
                FindBar()
            }

            // Not an HSplitView: it lays its panes out at their combined minimum and overflows a narrow window.
            HStack(spacing: 0) {
                transcriptColumn
                    .frame(minWidth: MainWindowLayout.transcriptMinWidth, maxWidth: .infinity)

                if showsInspector {
                    Divider()
                    TranscriptInspector()
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

            if TranslationStrip.shows(model.translationState) {
                TranslationStrip()
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
        .modifier(TranscriptMenuPopovers())
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

    private func applyPaneWidth(_ width: CGFloat) {
        let narrow = width < MainWindowLayout.inspectorCollapseWidth
        if paneIsNarrow != narrow { paneIsNarrow = narrow }
        if model.transcriptPaneIsNarrow != narrow { model.transcriptPaneIsNarrow = narrow }
        if !narrow, inspectorForcedAtNarrowWidth { inspectorForcedAtNarrowWidth = false }
    }
}
