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

enum TranscriptDisplayMode: String, CaseIterable, Identifiable {
    case transcript
    case segments
    var id: String { rawValue }
}

enum InspectorMode: String, CaseIterable, Identifiable {
    case format
    case info
    case actions
    var id: String { rawValue }
}

struct TranscriptPane: View {
    @Environment(AppModel.self) private var model
    @AppStorage("inspectorVisible", store: DefaultsStore.current) private var inspectorVisible: Bool = true
    @AppStorage("inspectorMode", store: DefaultsStore.current) private var inspectorModeRaw: String = InspectorMode.format.rawValue
    @State private var summarySheetOpen = false
    @State private var chatSheetOpen = false

    private var displayMode: TranscriptDisplayMode {
        model.transcriptDisplayMode
    }

    var body: some View {
        VStack(spacing: 0) {
            TranscriptHeaderBar(
                title: headerTitle,
                onAdvance: advanceToNext,
                onOpenSummary: { summarySheetOpen = true },
                onOpenChat: { chatSheetOpen = true }
            )
            Divider()

            if model.findIsOpen {
                FindBar()
            }

            // Fixed width rather than a split: an HSplitView lays its panes out at their
            // combined minimum and draws past the window when the detail column is narrower.
            HStack(spacing: 0) {
                transcriptColumn
                    .frame(minWidth: MainWindowLayout.transcriptMinWidth, maxWidth: .infinity)

                if inspectorVisible {
                    Divider()
                    TranscriptInspector(
                        mode: inspectorModeBinding,
                        inspectorVisible: $inspectorVisible
                    )
                    .frame(width: MainWindowLayout.inspectorWidth)
                }
            }
        }
        .sheet(isPresented: $summarySheetOpen) {
            SummarySheet().environment(model)
        }
        .sheet(isPresented: $chatSheetOpen) {
            ChatSheet().environment(model)
        }
        .task { model.refreshAIAvailability() }
        .axBranch("Transcript")
    }

    private var headerTitle: String {
        AppModel.transcriptDisplayTitle(
            sourceFileURL: model.sourceFileURL,
            entry: model.selectedEntryID.flatMap { model.libraryEntry(id: $0) },
            fallback: String(localized: "Untitled")
        )
    }

    private func advanceToNext() {
        guard let segments = model.transcript?.segments, !segments.isEmpty else { return }
        if let current = model.currentSegmentID,
           let idx = segments.firstIndex(where: { $0.id == current }),
           idx + 1 < segments.count {
            model.seek(to: segments[idx + 1])
        } else if let first = segments.first {
            model.seek(to: first)
        }
    }

    private var transcriptColumn: some View {
        VStack(spacing: 0) {
            transcriptBody
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            if model.hasVideo, let player = model.player {
                Divider()
                PlayerSurface(player: player)
                    .frame(height: 200)
                    .background(Color.black)
            }

            if model.player != nil {
                Divider()
                MediaBar()
            }
        }
    }

    @ViewBuilder
    private var transcriptBody: some View {
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

    private var inspectorModeBinding: Binding<InspectorMode> {
        Binding(
            get: { InspectorMode(rawValue: inspectorModeRaw) ?? .format },
            set: { inspectorModeRaw = $0.rawValue }
        )
    }
}
