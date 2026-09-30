import Foundation
import ParolaCore

extension AppModel {

    enum DropHalf: String, CaseIterable, Sendable {
        case now
        case queue
    }

    var dropZonePlan: DroppedFiles.ZonePlan {
        // The chat composer is a nested drop target: it wins the drop, so the overlay must not claim it.
        guard let payload = dropDragPayload, !dragOverComposer else { return .none }
        let linksWait: Bool = if case .links = payload { linkArrivalsDeferred } else { false }
        return DroppedFiles.plan(
            for: payload,
            batchEnabled: features.isEnabled(.batch),
            youtubeEnabled: features.isEnabled(.youtube),
            arrivalsDeferred: takeIsRunning || linksWait
        )
    }

    /// Above this many files from one drop, nothing is queued until the user says so.
    static let largeDropLimit = 200

    /// A drop over `largeDropLimit` files, waiting on the alert that asks whether to take it.
    struct PendingLargeDrop {
        let count: Int
        let deliver: @MainActor () -> Void
    }

    @discardableResult
    func drop(_ urls: [URL], on half: DropHalf) -> Task<Void, Never> {
        receive(urls) { [weak self] files in
            switch half {
            case .now: self?.transcribeNow(urls: files)
            case .queue: self?.addToQueue(urls: files)
            }
        }
    }

    /// Walks any folders off the main thread, then hands on what they hold as if those files had been dropped.
    @discardableResult
    func receive(_ urls: [URL], deliver: @escaping @MainActor ([URL]) -> Void) -> Task<Void, Never> {
        Task { [weak self] in
            let found = await DroppedFiles.classifyOffMain(urls).all
            guard let self else { return }
            guard found.count > Self.largeDropLimit else {
                deliver(found)
                return
            }
            // A second large drop joins the one still waiting, so one answer covers both.
            let waiting = pendingLargeDrop
            pendingLargeDrop = PendingLargeDrop(count: (waiting?.count ?? 0) + found.count) {
                waiting?.deliver()
                deliver(found)
            }
        }
    }

    func confirmLargeDrop() {
        let pending = pendingLargeDrop
        pendingLargeDrop = nil
        pending?.deliver()
    }

    func cancelLargeDrop() {
        pendingLargeDrop = nil
    }

    /// The Transcribe Now half: the first media file starts, the rest wait their turn rather
    /// than cancelling it — the same rule watched-folder arrivals follow.
    func transcribeNow(urls: [URL]) {
        let files = DroppedFiles.classify(urls)
        guard !files.isEmpty else { return }
        for url in files.subtitles { importSubtitle(fileURL: url) }
        takeLinks(files.links, behindMedia: !files.media.isEmpty)
        guard !files.media.isEmpty else {
            for project in files.projects {
                Task { [weak self] in await self?.openProjectDocument(at: project) }
            }
            return
        }
        if batchIsRunning {
            importBatchFiles(files.media)
            showBatchActivity()
            return
        }
        // The take's Stage stays up; the files wait for it.
        guard !takeIsRunning else {
            deferredArrivals.append(contentsOf: files.media)
            noteRunWaitsForTake()
            return
        }
        route = .transcript
        guard !transcribeTaskRunning else {
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
            takeLinks(files.links, behindMedia: false)
            for project in files.projects {
                Task { [weak self] in await self?.openProjectDocument(at: project) }
            }
            return
        }
        takeLinks(files.links, behindMedia: true)
        guard features.isEnabled(.batch) else {
            transcribeNow(urls: files.media)
            return
        }
        importBatchFiles(files.media)
        if !batchJobs.isEmpty { showBatchActivity() }
    }

    /// Every link a drop carries is taken: alone, the first starts and the rest queue; beside media, all wait for it.
    func takeLinks(_ links: [URL], behindMedia: Bool) {
        var waiting = links[...]
        if !behindMedia, let first = waiting.popFirst() {
            guard transcribeYouTube(urlString: first.absoluteString) != .rejected else { return }
        } else if !features.isEnabled(.youtube) {
            return
        }
        deferredLinks.append(contentsOf: waiting.map { .transcribe($0.absoluteString) })
    }

    /// Finder hands Open With one URL per callback, so a three-file selection arrives as three
    /// calls; collecting them makes it behave like the same three files dropped on the window.
    func collectOpenedFile(_ url: URL) {
        pendingOpenedFiles.append(url)
        openedFilesFlushTask?.cancel()
        openedFilesFlushTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled, let self else { return }
            self.openedFilesFlushTask = nil
            self.flushOpenedFiles()
        }
    }

    @discardableResult
    func flushOpenedFiles() -> Task<Void, Never>? {
        let urls = pendingOpenedFiles
        pendingOpenedFiles = []
        guard !urls.isEmpty else { return nil }
        return receive(urls) { [weak self] in self?.handleIncomingFiles($0) }
    }
}
