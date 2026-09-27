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
        /// Share one ledger between the watchers of one app so a file moved between two watched
        /// folders is not imported again.
        public var ledger: FolderWatcherLedger
        /// Off in tests that drive every rescan themselves and need a fixed order between folders.
        var observesFileSystem = true

        public init(
            recursive: Bool = true,
            settledInterval: Duration = .milliseconds(750),
            clock: any FolderWatcherClock = SystemFolderWatcherClock(),
            scheduler: any FolderWatcherScheduler = SystemFolderWatcherScheduler(),
            ledger: FolderWatcherLedger = FolderWatcherLedger()
        ) {
            self.recursive = recursive
            self.settledInterval = settledInterval
            self.clock = clock
            self.scheduler = scheduler
            self.ledger = ledger
        }
    }

    /// The inode when the volume reports one, so a rename or a move keeps the file's identity;
    /// otherwise the path.
    enum FileKey: Hashable, Sendable {
        case inode(UInt64)
        case path(String)
    }

    enum FileStatus: Sendable, Equatable {
        case settled
        case pending
    }

    private struct TrackedFile {
        var path: String
        var size: Int64
        var modified: Date
        var status: FileStatus
    }

    /// The media a watcher has accounted for, saved between launches so a file added while the app
    /// was quit still arrives and the files already there don't.
    public struct Baseline: Codable, Sendable, Equatable {
        public struct Entry: Codable, Sendable, Equatable {
            /// Relative to the watched folder, which can itself be renamed or moved.
            public var path: String
            public var inode: UInt64?
            public var size: Int64
            public var modified: Date
        }

        public var entries: [Entry]

        public init(entries: [Entry] = []) {
            self.entries = entries
        }
    }

    private let folderURL: URL
    /// Symlinks resolved, as the enumerator reports every path under it.
    private let rootURL: URL
    private let onNewMediaFile: @Sendable (URL) -> Void
    private let onBaselineChange: (@Sendable () -> Void)?
    private let options: Options
    private let eventQueue = DispatchQueue(label: "com.parola.folder-watch.\(UUID().uuidString)")
    private var fileDescriptor: Int32 = -1
    private var source: DispatchSourceFileSystemObject?
    // A vnode source only fires for the directory it watches, so recursive mode
    // needs one source per subdirectory, synced as directories come and go.
    private var subdirSources: [String: DispatchSourceFileSystemObject] = [:]
    private var files: [FileKey: TrackedFile] = [:]
    private var pending: Set<FileKey> = []
    private var scanTask: Task<Void, Never>?
    private var scanContinuation: AsyncStream<Void>.Continuation?
    private var settledTask: Task<Void, Never>?
    private var lastRescan: Task<Void, Never>?
    private var baselineChanged = false

    /// `onBaselineChange` fires after a scan or a settle check changes what `baseline()` returns.
    public init(
        folderURL: URL,
        options: Options = Options(),
        onBaselineChange: (@Sendable () -> Void)? = nil,
        onNewMediaFile: @escaping @Sendable (URL) -> Void
    ) {
        self.folderURL = folderURL
        self.rootURL = Self.realPath(folderURL)
        self.options = options
        self.onBaselineChange = onBaselineChange
        self.onNewMediaFile = onNewMediaFile
    }

    public init(folderURL: URL, onNewMediaFile: @escaping @Sendable (URL) -> Void) {
        self.init(folderURL: folderURL, options: Options(), onNewMediaFile: onNewMediaFile)
    }

    /// Without a baseline every file already in the folder counts as seen, as when a folder is first
    /// added. With one, files the baseline doesn't account for arrive once they settle.
    public func start(baseline: Baseline? = nil) async {
        guard source == nil else { return }
        let fd = folderURL.path.withCString { open($0, O_EVTONLY) }
        guard fd >= 0 else { return }
        fileDescriptor = fd
        let scan = await scanFolderOffActor()
        // stop() can run on this actor during the await above; if it did, it cleared fileDescriptor
        // and closed our fd — don't resurrect a source on a closed descriptor.
        guard fileDescriptor == fd else { return }
        files = [:]
        pending = []
        if let baseline {
            for entry in baseline.entries {
                let path = rootURL.path + "/" + entry.path
                let key = entry.inode.map(FileKey.inode) ?? .path(path)
                files[key] = TrackedFile(path: path, size: entry.size, modified: entry.modified, status: .settled)
            }
            reconcile(scan.files)
        } else {
            for file in scan.files {
                files[file.key] = TrackedFile(path: file.path, size: file.size, modified: file.modified, status: .settled)
            }
        }
        baselineChanged = true
        publishBaselineChange()
        if !pending.isEmpty {
            schedulePendingCheck()
        }

        // bufferingNewest(1): events that land while a rescan is running collapse into one trailing rescan.
        let (stream, continuation) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        scanContinuation = continuation
        scanTask = Task { [weak self] in
            for await _ in stream {
                await self?.checkForNewFiles()
            }
        }

        guard options.observesFileSystem else { return }
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
        pending.removeAll()
    }

    /// Rescans run one at a time: a scan that finished listing before a newer one must not apply its
    /// older picture of the folder on top.
    internal func checkForNewFiles() async {
        let previous = lastRescan
        let rescan = Task {
            await previous?.value
            await rescanFolder()
        }
        lastRescan = rescan
        await rescan.value
    }

    private func rescanFolder() async {
        let scan = await scanFolderOffActor()
        // A root that can't be listed (renamed away, unmounted) says nothing about its files.
        guard !scan.rootMissing else { return }
        syncSubdirWatchers(scan.directories)
        reconcile(scan.files)
        publishBaselineChange()
        if !pending.isEmpty {
            schedulePendingCheck()
        }
    }

    public func baseline() -> Baseline {
        let prefix = rootURL.path + "/"
        let entries: [Baseline.Entry] = files.compactMap { key, file in
            guard file.status == .settled, file.path.hasPrefix(prefix) else { return nil }
            var inode: UInt64?
            if case .inode(let number) = key { inode = number }
            return Baseline.Entry(
                path: String(file.path.dropFirst(prefix.count)),
                inode: inode,
                size: file.size,
                modified: file.modified
            )
        }
        return Baseline(entries: entries.sorted { $0.path < $1.path })
    }

    private func publishBaselineChange() {
        guard baselineChanged else { return }
        baselineChanged = false
        onBaselineChange?()
    }

    private func reconcile(_ listed: [ScannedFile]) {
        let now = options.clock.now()
        let listedKeys = Set(listed.map(\.key))
        var vanished: [String: FileKey] = [:]
        for (key, file) in files where !listedKeys.contains(key) {
            vanished[file.path] = key
        }

        for item in listed {
            if var known = files[item.key] {
                if known.status == .settled,
                   known.path != item.path || known.size != item.size || known.modified != item.modified {
                    known.size = item.size
                    known.modified = item.modified
                    baselineChanged = true
                }
                known.path = item.path
                files[item.key] = known
            } else if let departure = options.ledger.claim(item.key, size: item.size, modified: item.modified, now: now) {
                track(item, status: departure.status)
            } else if let oldKey = vanished[item.path], let old = files[oldKey],
                      old.size == item.size, old.modified == item.modified {
                // Same name, size and date under a new inode: an atomic save of the same bytes, or a
                // network volume that renumbered its files on remount.
                vanished.removeValue(forKey: item.path)
                files.removeValue(forKey: oldKey)
                pending.remove(oldKey)
                track(item, status: old.status)
            } else {
                track(item, status: .pending)
            }
        }

        for key in vanished.values {
            guard let gone = files.removeValue(forKey: key) else { continue }
            pending.remove(key)
            if gone.status == .settled { baselineChanged = true }
            options.ledger.depart(key, .init(size: gone.size, modified: gone.modified, status: gone.status, departedAt: now))
        }
    }

    private func track(_ item: ScannedFile, status: FileStatus) {
        files[item.key] = TrackedFile(path: item.path, size: item.size, modified: item.modified, status: status)
        if status == .pending {
            pending.insert(item.key)
        } else {
            pending.remove(item.key)
            baselineChanged = true
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
        guard !pending.isEmpty else { return }
        let now = options.clock.now()
        let cutoff = now.addingTimeInterval(-Self.intervalAsSeconds(options.settledInterval))
        for key in pending {
            guard var file = files[key] else {
                pending.remove(key)
                continue
            }
            let values = try? URL(fileURLWithPath: file.path)
                .resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            guard let values else {
                files.removeValue(forKey: key)
                pending.remove(key)
                continue
            }
            let mtime = values.contentModificationDate ?? file.modified
            let size = Int64(values.fileSize ?? 0)
            if mtime <= cutoff && size == file.size && size > 0 {
                file.status = .settled
                pending.remove(key)
                baselineChanged = true
                // A move from another watched folder can reach this watcher before that one notices
                // the file left; the settle delay gives it time to hand the file over.
                if options.ledger.claim(key, size: size, modified: mtime, now: now) == nil {
                    onNewMediaFile(URL(fileURLWithPath: file.path))
                }
            }
            file.size = size
            file.modified = mtime
            files[key] = file
        }
        publishBaselineChange()
        if !pending.isEmpty {
            schedulePendingCheck()
        }
    }

    private static func intervalAsSeconds(_ duration: Duration) -> Double {
        let comp = duration.components
        return Double(comp.seconds) + Double(comp.attoseconds) / 1e18
    }

    private struct ScannedFile: Sendable {
        var key: FileKey
        var path: String
        var size: Int64
        var modified: Date
    }

    private struct FolderScan: Sendable {
        var files: [ScannedFile] = []
        var directories: Set<String> = []
        var rootMissing = false
    }

    private static let scanKeys: [URLResourceKey] = [
        .isRegularFileKey, .isDirectoryKey, .fileIdentifierKey, .fileSizeKey, .contentModificationDateKey,
    ]

    /// GCD, not `Task.detached`: a detached job resuming actor work around the enumerator's
    /// NSURL bridging has crashed with EXC_ARM_DA_ALIGN before.
    private func scanFolderOffActor() async -> FolderScan {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                continuation.resume(returning: scanFolder())
            }
        }
    }

    private nonisolated func scanFolder() -> FolderScan {
        let fm = FileManager.default
        let keySet = Set(Self.scanKeys)
        var scan = FolderScan()
        func add(_ url: URL, _ values: URLResourceValues?) {
            if values?.isDirectory == true {
                scan.directories.insert(url.path)
            } else if values?.isRegularFile == true, Self.isMediaFile(url) {
                let path = url.path
                scan.files.append(ScannedFile(
                    key: values?.fileIdentifier.map(FileKey.inode) ?? .path(path),
                    path: path,
                    size: Int64(values?.fileSize ?? 0),
                    modified: values?.contentModificationDate ?? .distantPast
                ))
            }
        }
        guard options.recursive else {
            guard let contents = try? fm.contentsOfDirectory(
                at: rootURL, includingPropertiesForKeys: Self.scanKeys, options: []
            ) else { return FolderScan(rootMissing: true) }
            for url in contents {
                add(url, try? url.resourceValues(forKeys: keySet))
            }
            return scan
        }
        // The enumerator comes back empty, not nil, for a missing root.
        guard rootIsDirectory(), let enumerator = fm.enumerator(
            at: rootURL,
            includingPropertiesForKeys: Self.scanKeys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return FolderScan(rootMissing: true) }
        for case let url as URL in enumerator {
            add(url, try? url.resourceValues(forKeys: keySet))
        }
        guard rootIsDirectory() else { return FolderScan(rootMissing: true) }
        return scan
    }

    /// `realpath`, not `resolvingSymlinksInPath`, which strips `/private` where the enumerator keeps it.
    private static func realPath(_ url: URL) -> URL {
        guard let resolved = realpath(url.path, nil) else { return url.standardizedFileURL }
        defer { free(resolved) }
        return URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
    }

    private nonisolated func rootIsDirectory() -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: rootURL.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    internal var pendingPaths: Set<String> {
        Set(pending.compactMap { files[$0]?.path })
    }

    internal var trackedPaths: Set<String> {
        Set(files.values.map(\.path))
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
