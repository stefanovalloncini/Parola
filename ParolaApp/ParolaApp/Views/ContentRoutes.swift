import SwiftUI
import ParolaCore

struct ContentRoutes: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        routedContent
            .onChange(of: model.pendingExport) { _, format in
                if let format {
                    model.performExport(format)
                    model.pendingExport = nil
                }
            }
    }

    private var routedContent: some View {
        ZStack {
            content
                .id(routeID)
                .transition(.opacity)
        }
        .animation(reduceMotion ? nil : DS.Motion.route, value: routeID)
    }

    @ViewBuilder
    private var content: some View {
        if model.mode == .test, model.settingsRoutePreview {
            SettingsView()
        } else {
            switch model.route {
            case .batch:
                BatchView()
            case .queue:
                QueueView()
            case .transcript:
                transcriptContent
            }
        }
    }

    /// Coarse on purpose: one case per library filter keeps the list's identity across a category switch.
    private var routeID: RouteID {
        if model.mode == .test, model.settingsRoutePreview { return .settingsPreview }
        switch model.route {
        case .batch: return .batch
        case .queue: return .queue
        case .transcript:
            if !model.batchJobs.isEmpty { return .batchDetail }
            return showsLibraryBrowse ? .library : .phase
        }
    }

    private enum RouteID: Hashable {
        case settingsPreview
        case batch
        case queue
        case batchDetail
        case library
        case phase
    }

    @ViewBuilder
    private var transcriptContent: some View {
        if !model.batchJobs.isEmpty {
            // Fixed width rather than a split: TranscriptPane already nests an HSplitView, and
            // two nested ones overflow the window instead of compressing — the batch list ate
            // the slack until the sidebar and the inspector both clipped at their window edges.
            HStack(spacing: 0) {
                BatchSidebar()
                    .frame(width: 260)
                Divider()
                batchDetail
            }
        } else if showsLibraryBrowse {
            libraryBrowseList
        } else {
            phaseContent
        }
    }

    private var phaseContent: some View {
        ZStack {
            phaseView
                .id(phaseViewID)
                .transition(.opacity)
        }
        .animation(.easeInOut(duration: 0.3), value: phaseViewID)
    }

    @ViewBuilder
    private var phaseView: some View {
        switch model.phase {
        case .idle:
            EmptyDropZone()
        case .downloadingModel(let name, let progress):
            ProgressPane(title: "Downloading \(AppModel.modelLabel(name))", progress: progress)
        case .loadingModel(let name):
            ProgressPane(title: "Loading \(AppModel.modelLabel(name))…", progress: nil)
        case .transcribing(let file):
            LiveTranscribingPane(file: file)
        case .recording(let source):
            RecordingPane(source: source)
        case .exporting(let progress):
            ProgressPane(title: "Burning subtitles…", progress: progress)
        case .ready:
            if model.transcript != nil {
                TranscriptPane()
            } else {
                EmptyDropZone()
            }
        case .failed(let message):
            EmptyDropZone(errorMessage: message)
        }
    }

    private var phaseViewID: Int {
        switch model.phase {
        case .idle: 0
        case .downloadingModel: 1
        case .loadingModel: 2
        case .transcribing: 3
        case .recording: 4
        case .ready: 5
        case .failed: 6
        case .exporting: 7
        }
    }

    @ViewBuilder
    private var batchDetail: some View {
        if case .failed(let message) = model.phase {
            ErrorPane(message: message)
        } else if model.transcript != nil {
            TranscriptPane()
        } else {
            switch BatchDetailPlaceholder(
                isRunning: model.batchIsRunning,
                hasCompletedJob: model.batchJobs.contains { $0.status == .done }
            ) {
            case .running:
                ProgressPane(title: "Transcribing batch…", progress: nil)
            case .selectFile:
                ContentUnavailableView {
                    Label("Select a file", systemImage: "doc.text")
                } description: {
                    Text("Choose a completed file to see its transcript.")
                }
            case .noTranscripts:
                ContentUnavailableView {
                    Label("No transcripts", systemImage: "exclamationmark.triangle")
                } description: {
                    Text("None of these files was transcribed. Check the list for details.")
                }
            }
        }
    }

    private var showsLibraryBrowse: Bool {
        model.isBrowsingLibrary
    }

    /// One call site on purpose: an `if` per case would give each branch its own identity and tear the List down on every sidebar move.
    private var libraryBrowseList: some View {
        LibraryListView(
            category: LibraryListContent.browseCategory(
                filter: model.libraryFilter,
                searching: model.searchResults != nil
            ),
            searchResults: model.searchResults
        )
    }

}

/// Owns the route's only reads of the per-partial properties, which arrive several times a second.
/// Reading them from `ContentRoutes` instead would invalidate the whole detail column each time.
private struct LiveTranscribingPane: View {
    @Environment(AppModel.self) private var model
    let file: URL

    var body: some View {
        TranscribingPane(
            file: file,
            partial: model.filePartialText,
            progress: model.fileTranscribeFraction,
            expectsPartials: model.activeEngineStreamsPartials,
            stage: model.fileTranscribeStage
        )
    }
}

struct HideToolbarTitleIfAvailable: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.toolbar(removing: .title)
        } else {
            content
        }
    }
}
