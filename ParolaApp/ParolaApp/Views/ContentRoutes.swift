import SwiftUI

struct ContentRoutes: View {
    @EnvironmentObject var model: AppModel

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
        switch model.route {
        case .batch:
            BatchView()
        case .queue:
            QueueView()
        case .transcript:
            transcriptContent
        }
    }

    @ViewBuilder
    private var transcriptContent: some View {
        if !model.batchJobs.isEmpty {
            HSplitView {
                BatchSidebar()
                    .frame(minWidth: 240, idealWidth: 280)
                if model.transcript != nil {
                    TranscriptPane()
                } else {
                    ProgressPane(title: "Transcribing batch…", progress: nil)
                }
            }
        } else {
            switch model.phase {
            case .idle:
                EmptyDropZone()
            case .downloadingModel(let name, let progress):
                ProgressPane(title: "Downloading \(name)", progress: progress)
            case .loadingModel(let name):
                ProgressPane(title: "Loading \(name)…", progress: nil)
            case .transcribing(let file):
                TranscribingPane(file: file, partial: model.filePartialText)
            case .recording(let source):
                RecordingPane(source: source)
            case .ready:
                TranscriptPane()
            case .failed(let message):
                ErrorPane(message: message)
            }
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
