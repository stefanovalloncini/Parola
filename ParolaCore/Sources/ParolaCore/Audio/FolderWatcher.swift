import Foundation

public actor FolderWatcher {
    public static let audioExtensions: Set<String> = ["mp3", "wav", "m4a", "aac", "flac", "aif", "aiff", "caf", "opus", "ogg"]
    public static let videoExtensions: Set<String> = ["mp4", "mov", "m4v", "webm", "mkv", "avi", "wmv"]

    public static func isMediaFile(_ url: URL) -> Bool {
        isMediaFile(name: url.lastPathComponent)
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

    /// The inode, so a rename or a move inside one volume keeps the file's identity.
    struct FileKey: Hashable, Sendable {
        var inode: UInt64
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
            public var inode: UInt64
            public var size: Int64
            public var modified: Date
        }

        public var entries: [Entry]

        public init(entries: [Entry] = []) {
            self.entries = entries
        }
    }

    private struct DirectoryRecord {
        var modified: Date?
        var media: Set<FileKey> = []
        var subdirectories: [String: FileKey] = [:]
    }

    private let folderURL: URL
    /// Symlinks resolved, as `open` resolves them for the root's descriptor, so the paths the watcher
    /// lists are in the directory its source watches.
    private let rootPath: String
    private let onNewMediaFile: @Sendable (URL) -> Void
    private let onBaselineChange: (@Sendable () -> Void)?
    private let options: Options
    private let eventQueue = DispatchQueue(label: "com.parola.folder-watch.\(UUID().uuidString)")
    private var fileDescriptor: Int32 = -1
    private var source: DispatchSourceFileSystemObject?
    // A vnode source only fires for the directory it watches, so recursive mode
    // needs one source per subdirectory, synced as directories come and go.
    private var subdirSources: [String: DispatchSourceFileSystemObject] = [:]
    private var directories: [String: DirectoryRecord] = [:]
    private var files: [FileKey: TrackedFile] = [:]
    private var pending: Set<FileKey> = []
    private var dirty: Set<String> = []
    private var drainTask: Task<Void, Never>?
    private var eventTask: Task<Void, Never>?
    private var eventContinuation: AsyncStream<String>.Continuation?
    private var settledTask: Task<Void, Never>?
    private var baselineChanged = false
    private(set) var listedDirectoryCount = 0

    /// `onBaselineChange` fires after a scan or a settle check changes what `baseline()` returns.
    public init(
        folderURL: URL,
        options: Options = Options(),
        onBaselineChange: (@Sendable () -> Void)? = nil,
        onNewMediaFile: @escaping @Sendable (URL) -> Void
    ) {
        self.folderURL = folderURL
        self.rootPath = Self.realPath(folderURL)
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
        let request = ScanRequest(directories: [rootPath], knownSubdirectories: [:], recursive: options.recursive)
        let scan = await scanOffActor(request)
        // stop() can run on this actor during the await above; if it did, it cleared fileDescriptor
        // and closed our fd — don't resurrect a source on a closed descriptor.
        guard fileDescriptor == fd else { return }
        files = [:]
        pending = []
        directories = [:]
        guard !scan.missing.contains(rootPath) else { return }
        listedDirectoryCount += scan.listings.count

        let listed = scan.listings.flatMap(\.media)
        if let baseline {
            for entry in baseline.entries {
                let path = rootPath + "/" + entry.path
                files[FileKey(inode: entry.inode)] = TrackedFile(path: path, size: entry.size, modified: entry.modified, status: .settled)
            }
            let listedKeys = Set(listed.map(\.key))
            var vanished = pathIndex(files.keys.filter { !listedKeys.contains($0) })
            let now = options.clock.now()
            for item in listed {
                resolve(item, vanished: &vanished, now: now)
            }
            depart(Set(vanished.values), now: now)
        } else {
            for item in listed {
                files[item.key] = TrackedFile(path: item.path, size: item.size, modified: item.modified, status: .settled)
            }
        }
        for listing in scan.listings {
            directories[listing.path] = DirectoryRecord(
                modified: listing.modified,
                media: Set(listing.media.map(\.key)),
                subdirectories: listing.subdirectories
            )
        }
        baselineChanged = true
        publishBaselineChange()
        if !pending.isEmpty {
            schedulePendingCheck()
        }

        let (stream, continuation) = AsyncStream.makeStream(of: String.self)
        eventContinuation = continuation
        eventTask = Task { [weak self] in
            for await directory in stream {
                await self?.noteDirty(directory)
            }
        }

        guard options.observesFileSystem else { return }
        source = Self.makeSource(fd: fd, path: rootPath, continuation: continuation, queue: eventQueue)
        noteDirtyIfChangedSinceListing(rootPath)
        for path in directories.keys where path != rootPath {
            openSource(for: path)
        }
    }

    private static func makeSource(
        fd: Int32,
        path: String,
        continuation: AsyncStream<String>.Continuation,
        queue: DispatchQueue
    ) -> DispatchSourceFileSystemObject {
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: .write,
            queue: queue
        )
        src.setEventHandler {
            continuation.yield(path)
        }
        src.setCancelHandler { [fd] in
            close(fd)
        }
        src.resume()
        return src
    }

    private func openSource(for path: String) {
        guard options.recursive, options.observesFileSystem, subdirSources[path] == nil,
              let continuation = eventContinuation else { return }
        let fd = path.withCString { open($0, O_EVTONLY) }
        guard fd >= 0 else { return }
        subdirSources[path] = Self.makeSource(fd: fd, path: path, continuation: continuation, queue: eventQueue)
        noteDirtyIfChangedSinceListing(path)
    }

    /// A directory can change between its listing and its source going live, and no event reports that.
    private func noteDirtyIfChangedSinceListing(_ path: String) {
        guard let record = directories[path], FileInfo(path)?.modified != record.modified else { return }
        noteDirty(path)
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
        eventContinuation?.finish()
        eventContinuation = nil
        eventTask?.cancel()
        eventTask = nil
        dirty.removeAll()
        settledTask?.cancel()
        settledTask = nil
        pending.removeAll()
    }

    /// Rescans every directory the watcher knows, one level each.
    internal func checkForNewFiles() async {
        await markDirty(Set(directories.keys).union([rootPath]))
    }

    internal func markDirty(_ paths: Set<String>) async {
        for path in paths {
            noteDirty(path)
        }
        await drainTask?.value
    }

    /// Directories that change while a drain is listing join its next pass. One drain at a time: a
    /// listing taken before a newer one must not be applied on top of it.
    private func noteDirty(_ path: String) {
        dirty.insert(path)
        if drainTask == nil {
            drainTask = Task { await drainDirty() }
        }
    }

    private func drainDirty() async {
        while !dirty.isEmpty, fileDescriptor >= 0 {
            let batch = dirty
            dirty = []
            await rescan(batch)
        }
        drainTask = nil
    }

    private func rescan(_ batch: Set<String>) async {
        let known = batch.filter { directories[$0] != nil }
        guard !known.isEmpty else { return }
        let ordered = known
            .map { (path: $0, depth: $0.utf8.count { $0 == UInt8(ascii: "/") }) }
            .sorted { ($0.depth, $0.path) < ($1.depth, $1.path) }
        let request = ScanRequest(
            directories: ordered.map(\.path),
            knownSubdirectories: known.reduce(into: [:]) { $0[$1] = directories[$1]?.subdirectories },
            recursive: options.recursive
        )
        let scan = await scanOffActor(request)
        guard fileDescriptor >= 0 else { return }
        // A root that can't be listed (renamed away, unmounted) says nothing about its files.
        guard !scan.missing.contains(rootPath) else { return }
        listedDirectoryCount += scan.listings.count
        apply(scan.listings)
        publishBaselineChange()
        if !pending.isEmpty {
            schedulePendingCheck()
        }
    }

    private func apply(_ listings: [Listing]) {
        let now = options.clock.now()
        var candidates: Set<FileKey> = []
        for listing in listings {
            let previous = directories[listing.path] ?? DirectoryRecord()
            for (child, key) in previous.subdirectories where listing.subdirectories[child] != key {
                dropSubtree(child, departing: &candidates)
            }
            let listedKeys = Set(listing.media.map(\.key))
            let gone = previous.media.subtracting(listedKeys)
            candidates.formUnion(gone)
            var vanished = pathIndex(gone)
            for item in listing.media {
                resolve(item, vanished: &vanished, now: now)
            }
            directories[listing.path] = DirectoryRecord(
                modified: listing.modified,
                media: listedKeys,
                subdirectories: listing.subdirectories
            )
            if listing.path != rootPath {
                openSource(for: listing.path)
            }
        }
        let stillListed = candidates.filter { key in
            guard let file = files[key] else { return true }
            return directories[Self.parent(of: file.path)]?.media.contains(key) == true
        }
        depart(candidates.subtracting(stillListed), now: now)
    }

    private func dropSubtree(_ path: String, departing candidates: inout Set<FileKey>) {
        guard let record = directories.removeValue(forKey: path) else { return }
        candidates.formUnion(record.media)
        subdirSources.removeValue(forKey: path)?.cancel()
        for child in record.subdirectories.keys {
            dropSubtree(child, departing: &candidates)
        }
    }

    private func pathIndex(_ keys: some Sequence<FileKey>) -> [String: FileKey] {
        var index: [String: FileKey] = [:]
        for key in keys {
            if let file = files[key] { index[file.path] = key }
        }
        return index
    }

    private func resolve(_ item: ScannedFile, vanished: inout [String: FileKey], now: Date) {
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

    private func depart(_ keys: Set<FileKey>, now: Date) {
        for key in keys {
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

    public func baseline() -> Baseline {
        let prefix = rootPath + "/"
        let entries: [Baseline.Entry] = files.compactMap { key, file in
            guard file.status == .settled, file.path.hasPrefix(prefix) else { return nil }
            return Baseline.Entry(
                path: String(file.path.dropFirst(prefix.count)),
                inode: key.inode,
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
            guard let info = FileInfo(file.path) else {
                files.removeValue(forKey: key)
                pending.remove(key)
                continue
            }
            let mtime = info.modified
            let size = info.size
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

    /// GCD, not `Task.detached`: a detached job resuming actor work around the enumerator's
    /// NSURL bridging has crashed with EXC_ARM_DA_ALIGN before.
    private func scanOffActor(_ request: ScanRequest) async -> ScanResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: Self.scan(request))
            }
        }
    }

    private static func parent(of path: String) -> String {
        (path as NSString).deletingLastPathComponent
    }

    private static func realPath(_ url: URL) -> String {
        guard let resolved = realpath(url.path, nil) else { return url.standardizedFileURL.path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    internal var pendingPaths: Set<String> {
        Set(pending.compactMap { files[$0]?.path })
    }

    internal var trackedPaths: Set<String> {
        Set(files.values.map(\.path))
    }

    internal var watchedDirectories: Set<String> {
        Set(directories.keys)
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
