import SwiftUI
import ParolaCore

struct ContentRoutes: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        content
            .modifier(RouteAwareDropDestination(route: model.route, handler: handleDroppedURLs))
            .onChange(of: model.pendingExport) { _, format in
                if let format {
                    model.performExport(format)
                    model.pendingExport = nil
                }
            }
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

    @ViewBuilder
    private var transcriptContent: some View {
        if !model.batchJobs.isEmpty {
            HSplitView {
                BatchSidebar()
                    .frame(minWidth: 240, idealWidth: 280)
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
            TranscribingPane(file: file, partial: model.filePartialText, progress: model.fileTranscribeFraction, expectsPartials: model.activeEngineStreamsPartials)
        case .recording(let source):
            RecordingPane(source: source)
        case .ready:
            if model.transcript != nil {
                TranscriptPane()
            } else {
                EmptyDropZone()
            }
        case .failed(let message):
            ErrorPane(message: message)
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
        switch model.phase {
        case .idle, .ready:
            return model.searchResults != nil || model.libraryFilter != nil || model.libraryBrowsingAll
        default:
            return false
        }
    }

    @ViewBuilder
    private var libraryBrowseList: some View {
        if let results = model.searchResults {
            LibraryListView(category: nil, searchResults: results)
        } else if let filter = model.libraryFilter {
            LibraryListView(category: filter)
        } else {
            LibraryListView(category: nil)
        }
    }

    private func handleDroppedURLs(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        if urls.count == 1 {
            model.transcribe(fileURL: urls[0])
        } else {
            model.startBatch(urls: urls)
        }
    }
}

private struct RouteAwareDropDestination: ViewModifier {
    let route: AppModel.Route
    let handler: ([URL]) -> Void

    func body(content: Content) -> some View {
        if route == .batch {
            content
        } else {
            content.dropDestination(for: URL.self) { urls, _ in
                handler(urls)
                return !urls.isEmpty
            }
        }
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
