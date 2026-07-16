import Foundation

public actor FolderWatcher {
    public static let audioExtensions: Set<String> = ["mp3", "wav", "m4a", "aac", "flac", "aif", "aiff", "caf", "opus", "ogg"]
    public static let videoExtensions: Set<String> = ["mp4", "mov", "m4v", "webm", "mkv", "avi", "wmv"]

    public static func isMediaFile(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return audioExtensions.contains(ext) || videoExtensions.contains(ext)
    }

    public struct Options: Sendable {
        public var recursive: Bool
        public var settledInterval: Duration
        public var clock: any FolderWatcherClock
        public var scheduler: any FolderWatcherScheduler

        public init(
            recursive: Bool = true,
            settledInterval: Duration = .milliseconds(750),
            clock: any FolderWatcherClock = SystemFolderWatcherClock(),
            scheduler: any FolderWatcherScheduler = SystemFolderWatcherScheduler()
        ) {
            self.recursive = recursive
            self.settledInterval = settledInterval
            self.clock = clock
            self.scheduler = scheduler
        }
    }

    private let folderURL: URL
    private let onNewMediaFile: @Sendable (URL) -> Void
    private let options: Options
    private let eventQueue = DispatchQueue(label: "com.parola.folder-watch.\(UUID().uuidString)")
    private var fileDescriptor: Int32 = -1
    private var source: DispatchSourceFileSystemObject?
    // A vnode source only fires for the directory it watches, so recursive mode
    // needs one source per subdirectory, synced as directories come and go.
    private var subdirSources: [String: DispatchSourceFileSystemObject] = [:]
    private var knownFiles: Set<String> = []
    private var pendingFiles: [String: PendingFile] = [:]
    private var scanTask: Task<Void, Never>?
    private var scanContinuation: AsyncStream<Void>.Continuation?
    private var settledTask: Task<Void, Never>?

    private struct PendingFile {
        var modificationDate: Date
        var size: Int64
    }

    public init(
        folderURL: URL,
        options: Options = Options(),
        onNewMediaFile: @escaping @Sendable (URL) -> Void
    ) {
        self.folderURL = folderURL
        self.options = options
        self.onNewMediaFile = onNewMediaFile
    }

    public init(folderURL: URL, onNewMediaFile: @escaping @Sendable (URL) -> Void) {
        self.init(folderURL: folderURL, options: Options(), onNewMediaFile: onNewMediaFile)
    }

    public func start() async {
        guard source == nil else { return }
        let fd = folderURL.path.withCString { open($0, O_EVTONLY) }
        guard fd >= 0 else { return }
        fileDescriptor = fd
        let scan = await scanFolderOffActor()
        knownFiles = scan.files
        // stop() can run on this actor during the await above; if it did, it cleared fileDescriptor
        // and closed our fd — don't resurrect a source on a closed descriptor.
        guard fileDescriptor == fd else { return }

        // bufferingNewest(1): events that land while a rescan is running collapse into one trailing rescan.
        let (stream, continuation) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        scanContinuation = continuation
        scanTask = Task { [weak self] in
            for await _ in stream {
                await self?.checkForNewFiles()
            }
        }

        source = Self.makeSource(fd: fd, continuation: continuation, queue: eventQueue)
        syncSubdirWatchers(scan.directories)
    }

    private static func makeSource(
        fd: Int32,
        continuation: AsyncStream<Void>.Continuation,
        queue: DispatchQueue
    ) -> DispatchSourceFileSystemObject {
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: .write,
            queue: queue
        )
        src.setEventHandler {
            continuation.yield()
        }
        src.setCancelHandler { [fd] in
            close(fd)
        }
        src.resume()
        return src
    }

    private func syncSubdirWatchers(_ directories: Set<String>) {
        guard options.recursive, let continuation = scanContinuation else { return }
        for (path, src) in subdirSources where !directories.contains(path) {
            src.cancel()
            subdirSources.removeValue(forKey: path)
        }
        for path in directories where subdirSources[path] == nil {
            let fd = path.withCString { open($0, O_EVTONLY) }
            guard fd >= 0 else { continue }
            subdirSources[path] = Self.makeSource(fd: fd, continuation: continuation, queue: eventQueue)
        }
    }

    public func stop() {
        // The source's cancel handler owns the fd. If start() opened the fd but hasn't created the
        // source yet (it's parked in the initial scan await), close the fd here so it can't leak.
        if let source {
            source.cancel()
        } else if fileDescriptor >= 0 {
            close(fileDescriptor)
        }
        source = nil
        fileDescriptor = -1
        for src in subdirSources.values {
            src.cancel()
        }
        subdirSources.removeAll()
        scanContinuation?.finish()
        scanContinuation = nil
        scanTask?.cancel()
        scanTask = nil
        settledTask?.cancel()
        settledTask = nil
        pendingFiles.removeAll()
    }

    internal func checkForNewFiles() async {
        let scan = await scanFolderOffActor()
        syncSubdirWatchers(scan.directories)
        let current = scan.files
        let added = current.subtracting(knownFiles)
        // Replace, don't union: a vanished path must be forgotten so a same-name file recreated later
        // is re-detected, and so the set stays bounded to the folder's current contents.
        knownFiles = current

        let now = options.clock.now()
        for path in added {
            let url = URL(fileURLWithPath: path)
            guard Self.isMediaFile(url) else { continue }
            let attrs = try? FileManager.default.attributesOfItem(atPath: path)
            let mtime = attrs?[.modificationDate] as? Date ?? now
            let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
            pendingFiles[path] = PendingFile(modificationDate: mtime, size: size)
        }

        if !pendingFiles.isEmpty {
            schedulePendingCheck()
        }
    }

    private func schedulePendingCheck() {
        if settledTask != nil { return }
        let interval = options.settledInterval
        let scheduler = options.scheduler
        settledTask = Task { [weak self] in
            try? await scheduler.runTick(after: interval) { [weak self] in
                await self?.processPending()
            }
        }
    }

    private func processPending() {
        settledTask = nil
        guard !pendingFiles.isEmpty else { return }
        let now = options.clock.now()
        let cutoff = now.addingTimeInterval(-Self.intervalAsSeconds(options.settledInterval))
        var stillPending: [String: PendingFile] = [:]
        for (path, info) in pendingFiles {
            let attrs = try? FileManager.default.attributesOfItem(atPath: path)
            guard let attrs else { continue }
            let mtime = attrs[.modificationDate] as? Date ?? info.modificationDate
            let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
            if mtime <= cutoff && size == info.size && size > 0 {
                onNewMediaFile(URL(fileURLWithPath: path))
            } else {
                stillPending[path] = PendingFile(modificationDate: mtime, size: size)
            }
        }
        pendingFiles = stillPending
        if !pendingFiles.isEmpty {
            schedulePendingCheck()
        }
    }

    private static func intervalAsSeconds(_ duration: Duration) -> Double {
        let comp = duration.components
        return Double(comp.seconds) + Double(comp.attoseconds) / 1e18
    }

    private struct FolderScan: Sendable {
        var files: Set<String> = []
        var directories: Set<String> = []
    }

    private func scanFolderOffActor() async -> FolderScan {
        await Task.detached(priority: .userInitiated) { [self] in scanFolder() }.value
    }

    private nonisolated func scanFolder() -> FolderScan {
        let fm = FileManager.default
        guard options.recursive else {
            guard let contents = try? fm.contentsOfDirectory(atPath: folderURL.path) else { return FolderScan() }
            return FolderScan(files: Set(contents.map { folderURL.appendingPathComponent($0).path }))
        }
        guard let enumerator = fm.enumerator(
            at: folderURL,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return FolderScan() }
        var scan = FolderScan()
        for case let url as URL in enumerator {
            let resourceValues = try? url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey])
            if resourceValues?.isDirectory == true {
                scan.directories.insert(url.path)
            } else if resourceValues?.isRegularFile == true {
                scan.files.insert(url.path)
            }
        }
        return scan
    }
}

public protocol FolderWatcherClock: Sendable {
    func now() -> Date
}

public struct SystemFolderWatcherClock: FolderWatcherClock {
    public init() {}
    public func now() -> Date { Date() }
}

public protocol FolderWatcherScheduler: Sendable {
    func runTick(after interval: Duration, _ body: @Sendable @escaping () async -> Void) async throws
}

public struct SystemFolderWatcherScheduler: FolderWatcherScheduler {
    public init() {}
    public func runTick(after interval: Duration, _ body: @Sendable @escaping () async -> Void) async throws {
        try await Task.sleep(for: interval)
        await body()
    }
}
