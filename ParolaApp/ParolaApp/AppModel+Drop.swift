import Foundation
import ParolaCore

extension AppModel {

    enum DropHalf: String, CaseIterable, Sendable {
        case now
        case queue
    }

    var dropZonePlan: DroppedFiles.ZonePlan {
        guard let payload = dropDragPayload else { return .none }
        return DroppedFiles.plan(
            for: payload,
            batchEnabled: features.isEnabled(.batch),
            youtubeEnabled: features.isEnabled(.youtube),
            arrivalsDeferred: phaseDefersArrivals
        )
    }

    func drop(_ urls: [URL], on half: DropHalf) {
        switch half {
        case .now: transcribeNow(urls: urls)
        case .queue: addToQueue(urls: urls)
        }
    }

    /// The Transcribe Now half: the first media file starts, the rest wait their turn rather
    /// than cancelling it — the same rule watched-folder arrivals follow.
    func transcribeNow(urls: [URL]) {
        let files = DroppedFiles.classify(urls)
        guard !files.isEmpty else { return }
        if let link = files.links.first, files.files.isEmpty {
            transcribeYouTube(urlString: link.absoluteString)
            return
        }
        for url in files.subtitles { importSubtitle(fileURL: url) }
        guard !files.media.isEmpty else {
            if let project = files.projects.first {
                Task { [weak self] in await self?.openProjectDocument(at: project) }
            }
            return
        }
        if batchIsRunning {
            addBatchFiles(files.media)
            route = .batch
            return
        }
        route = .transcript
        guard !phaseDefersArrivals, !transcribeTaskRunning else {
            deferredArrivals.append(contentsOf: files.media)
            return
        }
        transcribe(fileURL: files.media[0])
        deferredArrivals.append(contentsOf: files.media.dropFirst())
    }

    /// The Add to Queue half. A gated build has no queue to add to, so the files still get
    /// transcribed rather than landing on a failure pane.
    func addToQueue(urls: [URL]) {
        let files = DroppedFiles.classify(urls)
        guard !files.isEmpty else { return }
        for url in files.subtitles { importSubtitle(fileURL: url) }
        guard !files.media.isEmpty else {
            if let project = files.projects.first {
                Task { [weak self] in await self?.openProjectDocument(at: project) }
            }
            return
        }
        guard features.isEnabled(.batch) else {
            transcribeNow(urls: files.media)
            return
        }
        addBatchFiles(files.media)
        if !batchJobs.isEmpty { route = .batch }
    }

    /// Finder hands Open With one URL per callback, so a three-file selection arrives as three
    /// calls; collecting them makes it behave like the same three files dropped on the window.
    func collectOpenedFile(_ url: URL) {
        pendingOpenedFiles.append(url)
        openedFilesFlushTask?.cancel()
        openedFilesFlushTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            self?.flushOpenedFiles()
        }
    }

    func flushOpenedFiles() {
        openedFilesFlushTask?.cancel()
        openedFilesFlushTask = nil
        let urls = pendingOpenedFiles
        pendingOpenedFiles = []
        guard !urls.isEmpty else { return }
        handleIncomingFiles(urls)
    }
}
