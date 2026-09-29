import Foundation

public actor FolderWatcher {
    public static let audioExtensions: Set<String> = ["mp3", "wav", "m4a", "aac", "flac", "aif", "aiff", "caf", "opus", "ogg"]
    public static let videoExtensions: Set<String> = ["mp4", "mov", "m4v", "webm", "mkv", "avi", "wmv"]

    public static func isMediaFile(_ url: URL) -> Bool {
        isMediaFile(name: url.lastPathComponent)
    }

    public struct Options: Sendable {
        public var recursive: Bool
        /// The time between two checks of a file that is still arriving.
        public var settledInterval: Duration
        /// How many checks in a row must find the same size and date before a file arrives; the listing
        /// that found the file is not one of them.
        public var stableChecks: Int
        /// A file that changes this soon after it arrived (a copy that stalled, a recorder that was
        /// paused) arrives again once it settles.
        public var reemitWindow: Duration
        public var clock: any FolderWatcherClock
        public var scheduler: any FolderWatcherScheduler
        /// Share one ledger between the watchers of one app so a file moved between two watched
        /// folders is not imported again.
        public var ledger: FolderWatcherLedger
        /// Where directory listings run.
        public var scanQueue: DispatchQueue
        /// Off in tests that drive every rescan themselves and need a fixed order between folders.
        var observesFileSystem = true
        var openDirectory: @Sendable (String) -> Int32 = { path in path.withCString { open($0, O_EVTONLY) } }
        var lister: Lister = { FolderWatcher.list($0, recursive: $1) }
        var fileSystemName: @Sendable (Int32) -> String? = FolderWatcher.fileSystemName
        var sourceBudget = FolderSourceBudget.shared
        var cloud = CloudProbe.system
        /// Download checks a placeholder gets before the watcher reads it to make it download.
        var placeholderChecks = 10

        public init(
            recursive: Bool = true,
            settledInterval: Duration = .seconds(1),
            stableChecks: Int = 3,
            reemitWindow: Duration = .seconds(600),
            clock: any FolderWatcherClock = SystemFolderWatcherClock(),
            scheduler: any FolderWatcherScheduler = SystemFolderWatcherScheduler(),
            ledger: FolderWatcherLedger = FolderWatcherLedger(),
            scanQueue: DispatchQueue = .global(qos: .utility)
        ) {
            self.recursive = recursive
            self.settledInterval = settledInterval
            self.stableChecks = stableChecks
            self.reemitWindow = reemitWindow
            self.clock = clock
            self.scheduler = scheduler
            self.ledger = ledger
            self.scanQueue = scanQueue
        }
    }

    /// The inode, so a rename or a move inside one volume keeps the file's identity.
    struct FileKey: Hashable, Sendable {
        var inode: UInt64
    }

    enum FileStatus: Sendable, Equatable {
        /// There before the watch began: a change to it is not an arrival.
        case existing
        case pending
        case emitted(at: Date)
    }

    private struct PendingCheck {
        var stableChecks = 0
        var downloadRequested = false
        var isUbiquitous: Bool?
        var dueTick: Int
        var backoff = 1
        var downloadChecks = 0
        var materializing = false
    }

    /// The longest a file waiting on Finder or on a download goes between checks, in settle intervals.
    static let longestBackoff = 32

    struct CloudProbe: Sendable {
        var isUbiquitous: @Sendable (String) -> Bool
        var isDownloaded: @Sendable (String) -> Bool
        var requestDownload: @Sendable (String) throws -> Void
        /// Reading a byte makes a File Provider placeholder download, where a download request may not.
        var materialize: @Sendable (String) throws -> Void

        static let system = CloudProbe(
            isUbiquitous: { path in
                (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.isUbiquitousItemKey]))?.isUbiquitousItem == true
            },
            isDownloaded: { path in
                let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey])
                return values?.ubiquitousItemDownloadingStatus == .current
            },
            requestDownload: { path in
                try FileManager.default.startDownloadingUbiquitousItem(at: URL(fileURLWithPath: path))
            },
            materialize: { path in
                let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
                defer { try? handle.close() }
                _ = try handle.read(upToCount: 1)
            }
        )
    }

    struct TrackedFile {
        var path: String
        var size: Int64
        var modified: Date
        var created: Date?
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
            public var emittedAt: Date?
            /// The birth time, when the volume keeps one; tells a new file from an old one under a reused inode.
            public var created: Date?
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

    public enum State: Sendable, Equatable {
        case idle
        case watching
        /// The folder couldn't be opened or listed when the watch started.
        case unavailable
        /// The folder was renamed, moved or deleted while watched. The watcher stops looking and keeps
        /// what it knew, for a new watcher started wherever the folder is now.
        case lost
        /// The folder's volume was unmounted while watched; like `lost`, but only a mount brings it back.
        case unmounted
    }

    enum Event: Sendable, Equatable {
        case changed(String)
        case rootLost
        case rootUnmounted
    }

    private let folderURL: URL
    /// Symlinks resolved off the caller's thread in `start`, so listed paths name what the root source watches.
    private var rootPath: String
    private let onNewMediaFile: @Sendable (URL) -> Void
    private let onBaselineChange: (@Sendable () -> Void)?
    private let onStateChange: (@Sendable (State) -> Void)?
    private let options: Options
    private let eventQueue = DispatchQueue(label: "com.parola.folder-watch.\(UUID().uuidString)")
    private var fileDescriptor: Int32 = -1
    private var source: DispatchSourceFileSystemObject?
    // A vnode source only fires for the directory it watches, so recursive mode
    // needs one source per subdirectory, synced as directories come and go.
    private var subdirSources: [String: DispatchSourceFileSystemObject] = [:]
    private var directories: [String: DirectoryRecord] = [:]
    private var files: [FileKey: TrackedFile] = [:]
    private var pending: [FileKey: PendingCheck] = [:]
    private var watchedAfterEmit: Set<FileKey> = []
    private var dirty: Set<String> = []
    private var rootInode: UInt64?
    /// APFS and HFS+ never hand a deleted file's inode to a new one; FAT, exFAT and SMB or NFS shares can.
    private var inodesAreUnique = false
    /// Directories without a source (out of descriptors) or whose last listing failed: relisted on every pass.
    private var unsourced: Set<String> = []
    private var unlisted: Set<String> = []
    private var polls: [String: Poll] = [:]

    private struct Poll {
        var dueTick: Int
        var backoff = 1
    }
    private var drainTask: Task<Void, Never>?
    private var eventTask: Task<Void, Never>?
    private var eventContinuation: AsyncStream<Event>.Continuation?
    private var settledTask: Task<Void, Never>?
    /// Settle intervals since the watch began; files and polls come due at a tick number.
    private var currentTick = 0
    private var armedTick: Int?
    private var tickGeneration = 0
    private var baselineChanged = false
    private var seed: Baseline?
    private var hasScanned = false
    private(set) var listedDirectoryCount = 0
    public private(set) var state: State = .idle

    /// `onBaselineChange` fires after a scan or a settle check changes what `baseline()` returns;
    /// `onStateChange` whenever `state` changes on its own, not for `start()` or `stop()` returning.
    public init(
        folderURL: URL,
        options: Options = Options(),
        onBaselineChange: (@Sendable () -> Void)? = nil,
        onStateChange: (@Sendable (State) -> Void)? = nil,
        onNewMediaFile: @escaping @Sendable (URL) -> Void
    ) {
        self.folderURL = folderURL
        self.rootPath = folderURL.standardizedFileURL.path
        self.options = options
        self.onBaselineChange = onBaselineChange
        self.onStateChange = onStateChange
        self.onNewMediaFile = onNewMediaFile
    }

    public init(folderURL: URL, onNewMediaFile: @escaping @Sendable (URL) -> Void) {
        self.init(folderURL: folderURL, options: Options(), onNewMediaFile: onNewMediaFile)
    }

    /// Without a baseline every file already in the folder counts as seen, as when a folder is first
    /// added. With one, files the baseline doesn't account for arrive once they settle. Ends in
    /// `.watching`, or `.unavailable` when the folder can't be opened.
    public func start(baseline: Baseline? = nil) async {
        guard fileDescriptor < 0 else { return }
        seed = baseline
        hasScanned = false
        let fd = options.openDirectory(folderURL.path)
        guard fd >= 0 else {
            state = .unavailable
            return
        }
        fileDescriptor = fd
        rootPath = await resolveRootOffActor()
        guard fileDescriptor == fd else { return }
        var rootStat = stat()
        rootInode = fstat(fd, &rootStat) == 0 ? UInt64(rootStat.st_ino) : nil
        inodesAreUnique = ["apfs", "hfs"].contains(options.fileSystemName(fd) ?? "")
        let request = ScanRequest(
            directories: [rootPath], knownSubdirectories: [:], recursive: options.recursive, lister: options.lister
        )
        let scan = await scanOffActor(request)
        // stop() can run on this actor during the await above; if it did, it cleared fileDescriptor
        // and closed our fd — don't resurrect a source on a closed descriptor.
        guard fileDescriptor == fd else { return }
        guard !scan.missing.contains(rootPath), !scan.failed.contains(rootPath) else {
            tearDown()
            state = .unavailable
            return
        }
        files = [:]
        pending = [:]
        watchedAfterEmit = []
        directories = [:]
        unlisted = scan.failed
        listedDirectoryCount += scan.listings.count

        let listed = scan.listings.flatMap(\.media)
        if let baseline {
            let now = options.clock.now()
            for entry in baseline.entries {
                let key = FileKey(inode: entry.inode)
                let path = rootPath + "/" + entry.path
                files[key] = TrackedFile(
                    path: path, size: entry.size, modified: entry.modified, created: entry.created, status: .existing
                )
                setStatus(entry.emittedAt.map { .emitted(at: $0) } ?? .existing, for: key, now: now)
            }
            let listedKeys = Set(listed.map(\.key))
            var vanished = pathIndex(files.keys.filter { !listedKeys.contains($0) })
            for item in listed {
                resolve(item, vanished: &vanished, now: now)
            }
            depart(Set(vanished.values), now: now)
        } else {
            for item in listed {
                files[item.key] = TrackedFile(
                    path: item.path, size: item.size, modified: item.modified, created: item.created, status: .existing
                )
            }
        }
        for listing in scan.listings {
            directories[listing.path] = DirectoryRecord(
                modified: listing.modified,
                media: Set(listing.media.map(\.key)),
                subdirectories: listing.subdirectories
            )
        }
        hasScanned = true
        seed = nil
        baselineChanged = true
        publishBaselineChange()
        scheduleSettleTick()

        let (stream, continuation) = AsyncStream.makeStream(of: Event.self)
        eventContinuation = continuation
        eventTask = Task { [weak self] in
            for await event in stream {
                switch event {
                case .changed(let directory): await self?.noteDirty(directory)
                case .rootLost: await self?.lose(.lost)
                case .rootUnmounted: await self?.lose(.unmounted)
                }
            }
        }
        state = .watching

        guard options.observesFileSystem else { return }
        source = Self.makeSource(fd: fd, path: rootPath, isRoot: true, continuation: continuation, queue: eventQueue)
        noteDirtyIfChangedSinceListing(rootPath)
        for path in directories.keys where path != rootPath {
            openSource(for: path)
        }
        scheduleSettleTick()
    }

    /// The root also reports being renamed, deleted or unmounted: its path no longer leads to it.
    private static func makeSource(
        fd: Int32,
        path: String,
        isRoot: Bool = false,
        budget: FolderSourceBudget? = nil,
        continuation: AsyncStream<Event>.Continuation,
        queue: DispatchQueue
    ) -> DispatchSourceFileSystemObject {
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: isRoot ? [.write, .rename, .delete, .revoke] : .write,
            queue: queue
        )
        src.setEventHandler { [weak src] in
            guard let src else { return }
            continuation.yield(event(for: src.data, at: path))
        }
        src.setCancelHandler { [fd] in
            close(fd)
            budget?.release()
        }
        src.resume()
        return src
    }

    static func event(for data: DispatchSource.FileSystemEvent, at path: String) -> Event {
        if data.contains(.revoke) { return .rootUnmounted }
        if !data.isDisjoint(with: [.rename, .delete]) { return .rootLost }
        return .changed(path)
    }

    private func openSource(for path: String) {
        guard options.recursive, options.observesFileSystem, subdirSources[path] == nil,
              let continuation = eventContinuation else { return }
        let budget = options.sourceBudget
        guard budget.acquire() else {
            unsourced.insert(path)
            return
        }
        let fd = options.openDirectory(path)
        guard fd >= 0 else {
            budget.release()
            unsourced.insert(path)
            return
        }
        unsourced.remove(path)
        subdirSources[path] = Self.makeSource(
            fd: fd, path: path, budget: budget, continuation: continuation, queue: eventQueue
        )
        noteDirtyIfChangedSinceListing(path)
    }

    /// A directory can change between its listing and its source going live, and no event reports that.
    private func noteDirtyIfChangedSinceListing(_ path: String) {
        guard let record = directories[path], FileInfo(path)?.modified != record.modified else { return }
        noteDirty(path)
    }

    public func stop() {
        tearDown()
        state = .idle
    }

    func lose(_ reason: State) {
        guard state == .watching else { return }
        tearDown()
        state = reason
        onStateChange?(reason)
    }

    private func tearDown() {
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
        unsourced.removeAll()
        unlisted.removeAll()
        polls.removeAll()
        settledTask?.cancel()
        settledTask = nil
        armedTick = nil
        tickGeneration += 1
        pending.removeAll()
        watchedAfterEmit.removeAll()
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

    /// One drain at a time, so an older listing never lands on a newer one; changes during a drain join its next pass.
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
        let walks = batch.filter { directories[$0] == nil && unlisted.contains($0) }
        guard !known.isEmpty || !walks.isEmpty else { return }
        let ordered = known
            .map { (path: $0, depth: $0.utf8.count { $0 == UInt8(ascii: "/") }) }
            .sorted { ($0.depth, $0.path) < ($1.depth, $1.path) }
        let request = ScanRequest(
            directories: ordered.map(\.path),
            walks: walks.sorted(),
            knownSubdirectories: known.reduce(into: [:]) { $0[$1] = directories[$1]?.subdirectories },
            recursive: options.recursive,
            lister: options.lister
        )
        let scan = await scanOffActor(request)
        guard fileDescriptor >= 0 else { return }
        // A root that can't be listed (renamed away, unmounted) says nothing about its files.
        let movedRoot = scan.listings.contains { $0.path == rootPath && rootInode != nil && $0.inode != rootInode }
        if scan.missing.contains(rootPath) || movedRoot {
            lose(.lost)
            return
        }
        unlisted.subtract(scan.listings.map(\.path))
        unlisted.subtract(scan.missing)
        unlisted.formUnion(scan.failed)
        listedDirectoryCount += scan.listings.count
        apply(scan.listings)
        publishBaselineChange()
        scheduleSettleTick()
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
        unsourced.remove(path)
        unlisted.remove(path)
        polls[path] = nil
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

    private func isSameInode(_ record: TrackedFile, as item: ScannedFile) -> Bool {
        inodesAreUnique || Self.isSameFile(record, as: item)
    }

    /// For volumes that reuse inodes. FAT keeps local time, so a time-zone change shifts both dates alike;
    /// `utimes` to an earlier date drags the birth time back onto the modification date.
    static func isSameFile(_ record: TrackedFile, as item: ScannedFile) -> Bool {
        guard let recorded = record.created, let listed = item.created else {
            return record.path == item.path || (record.size == item.size && record.modified == item.modified)
        }
        if listed == recorded { return true }
        if listed > recorded {
            let birthShift = listed.timeIntervalSince(recorded)
            let dateShift = item.modified.timeIntervalSince(record.modified)
            return record.path == item.path && record.size == item.size
                && abs(birthShift - dateShift) < 0.001 && isTimeZoneShift(birthShift)
        }
        return listed == item.modified
    }

    /// Whole quarter hours up to 26 h, within FAT's 2 s rounding: what a time-zone or DST change can do to a date.
    static func isTimeZoneShift(_ shift: TimeInterval) -> Bool {
        let quarterHour: TimeInterval = 15 * 60
        let offQuarter = abs(shift - (shift / quarterHour).rounded() * quarterHour)
        return abs(shift) <= 26 * 3600 && offQuarter <= 2
    }

    private func resolve(_ item: ScannedFile, vanished: inout [String: FileKey], now: Date) {
        if let known = files[item.key], !isSameInode(known, as: item) {
            forget(item.key)
        }
        if files[item.key] != nil {
            refresh(item.key, with: item, now: now)
        } else if let departure = options.ledger.claim(
            item.key, size: item.size, modified: item.modified, created: item.created, now: now
        ) {
            track(item, status: departure.status, now: now)
        } else if let oldKey = vanished[item.path], let old = files[oldKey],
                  !FolderWatcherLedger.isLater(item.created, than: old.created)
                    || (old.size == item.size && old.modified == item.modified) {
            // The same file saved again under a new inode: judged like a change written in place.
            vanished.removeValue(forKey: item.path)
            forget(oldKey)
            files[item.key] = TrackedFile(
                path: old.path, size: old.size, modified: old.modified, created: old.created, status: .pending
            )
            setStatus(old.status, for: item.key, now: now)
            refresh(item.key, with: item, now: now)
        } else {
            track(item, status: .pending, now: now)
        }
    }

    /// A changed file that was already there is updated; one that arrived moments ago arrives again.
    private func refresh(_ key: FileKey, with item: ScannedFile, now: Date) {
        guard var known = files[key] else { return }
        let changed = known.size != item.size || known.modified != item.modified
        let moved = known.path != item.path
        let reborn = item.created != nil && item.created != known.created
        known.path = item.path
        if known.status != .pending, changed || moved || reborn {
            known.size = item.size
            known.modified = item.modified
            baselineChanged = true
        }
        known.created = item.created ?? known.created
        files[key] = known
        if known.status == .pending, changed {
            pending[key]?.dueTick = currentTick + 1
            pending[key]?.backoff = 1
        }
        if case .emitted(let at) = known.status, changed, arrivesAgain(modified: item.modified, emittedAt: at) {
            setStatus(.pending, for: key, now: now)
        }
    }

    private func depart(_ keys: Set<FileKey>, now: Date) {
        var departures: [FileKey: FolderWatcherLedger.Departure] = [:]
        for key in keys {
            guard let gone = forget(key) else { continue }
            departures[key] = .init(
                size: gone.size, modified: gone.modified, created: gone.created, status: gone.status, departedAt: now
            )
        }
        options.ledger.depart(departures, now: now)
    }

    @discardableResult
    private func forget(_ key: FileKey) -> TrackedFile? {
        guard let gone = files.removeValue(forKey: key) else { return nil }
        pending[key] = nil
        watchedAfterEmit.remove(key)
        if gone.status != .pending { baselineChanged = true }
        return gone
    }

    private func track(_ item: ScannedFile, status: FileStatus, now: Date) {
        files[item.key] = TrackedFile(
            path: item.path, size: item.size, modified: item.modified, created: item.created, status: .pending
        )
        setStatus(status, for: item.key, now: now)
    }

    private func setStatus(_ status: FileStatus, for key: FileKey, now: Date) {
        guard let previous = files[key]?.status else { return }
        files[key]?.status = status
        if previous != status, previous != .pending || status != .pending {
            baselineChanged = true
        }
        switch status {
        case .pending:
            if pending[key] == nil { pending[key] = PendingCheck(dueTick: currentTick + 1) }
            watchedAfterEmit.remove(key)
        case .emitted(let at):
            pending[key] = nil
            if now < at.addingTimeInterval(Self.seconds(options.reemitWindow)) {
                watchedAfterEmit.insert(key)
            } else {
                watchedAfterEmit.remove(key)
            }
        case .existing:
            pending[key] = nil
            watchedAfterEmit.remove(key)
        }
    }

    /// Judged by the file's own date, so a change that happened while the app was quit counts too.
    private func arrivesAgain(modified: Date, emittedAt: Date) -> Bool {
        modified <= emittedAt.addingTimeInterval(Self.seconds(options.reemitWindow))
    }

    /// Until the first scan is applied this is the baseline the watcher was started with, or nil:
    /// an empty folder and a folder not listed yet must not look alike.
    public func baseline() -> Baseline? {
        guard hasScanned else { return seed }
        let prefix = rootPath + "/"
        let entries: [Baseline.Entry] = files.compactMap { key, file in
            guard file.status != .pending, file.path.hasPrefix(prefix) else { return nil }
            var emittedAt: Date?
            if case .emitted(let at) = file.status { emittedAt = at }
            return Baseline.Entry(
                path: String(file.path.dropFirst(prefix.count)),
                inode: key.inode,
                size: file.size,
                modified: file.modified,
                emittedAt: emittedAt,
                created: file.created
            )
        }
        return Baseline(entries: entries.sorted { $0.path < $1.path })
    }

    private func publishBaselineChange() {
        guard baselineChanged else { return }
        baselineChanged = false
        onBaselineChange?()
    }

    /// Arms the tick for whatever comes due first, and re-arms when something new comes due sooner.
    private func scheduleSettleTick() {
        var dues = pending.values.map(\.dueTick)
        dues += unsourced.union(unlisted).map { polls[$0]?.dueTick ?? currentTick + 1 }
        if !watchedAfterEmit.isEmpty { dues.append(currentTick + 1) }
        guard let firstDue = dues.min() else { return }
        let due = max(firstDue, currentTick + 1)
        if settledTask != nil, let armedTick, armedTick <= due { return }
        settledTask?.cancel()
        tickGeneration += 1
        let generation = tickGeneration
        armedTick = due
        let interval = options.settledInterval * (due - currentTick)
        let scheduler = options.scheduler
        settledTask = Task { [weak self] in
            try? await scheduler.runTick(after: interval) { [weak self] in
                await self?.settleTick(generation, reaching: due)
            }
        }
    }

    private func settleTick(_ generation: Int, reaching tick: Int) {
        guard generation == tickGeneration else { return }
        settledTask = nil
        armedTick = nil
        currentTick = tick
        let now = options.clock.now()
        for key in pending.keys {
            checkPending(key, now: now)
        }
        for key in watchedAfterEmit {
            recheckEmitted(key, now: now)
        }
        pollUnwatchedDirectories()
        publishBaselineChange()
        scheduleSettleTick()
    }

    /// Directories without a source or a good listing are listed on a backoff, from every tick up to every 32.
    private func pollUnwatchedDirectories() {
        let unwatched = unsourced.union(unlisted)
        polls = polls.filter { unwatched.contains($0.key) }
        for path in unwatched {
            var poll = polls[path] ?? Poll(dueTick: currentTick)
            guard poll.dueTick <= currentTick else { continue }
            noteDirty(path)
            poll.dueTick = currentTick + poll.backoff + 1
            poll.backoff = min(poll.backoff * 2, Self.longestBackoff)
            polls[path] = poll
        }
    }

    private func checkPending(_ key: FileKey, now: Date) {
        guard let file = files[key], var check = pending[key] else {
            pending[key] = nil
            return
        }
        guard check.dueTick <= currentTick else { return }
        check.dueTick = currentTick + 1
        guard let info = FileInfo(file.path) else {
            forget(key)
            return
        }
        if check.isUbiquitous == nil {
            check.isUbiquitous = options.cloud.isUbiquitous(file.path)
        }
        let observation = SettleObservation(
            size: info.size,
            modified: info.modified,
            created: info.created,
            isDataless: info.isDataless || (check.isUbiquitous == true && !options.cloud.isDownloaded(file.path))
        )
        let verdict = Self.settle(
            observation, after: (file.size, file.modified), checks: &check.stableChecks, now: now, options: options
        )
        if info.size != file.size || info.modified != file.modified {
            check.isUbiquitous = nil
        }
        files[key]?.size = info.size
        files[key]?.modified = info.modified
        switch verdict {
        case .wait:
            check.backoff = 1
            pending[key] = check
        case .hold:
            backOff(&check)
            pending[key] = check
        case .download:
            if !check.downloadRequested {
                check.downloadRequested = true
                do {
                    try options.cloud.requestDownload(file.path)
                } catch {
                    ParolaLog.error(.library, "a watched cloud file's download could not start", [.error: .error(error)])
                }
            }
            check.downloadChecks += 1
            if check.downloadChecks >= options.placeholderChecks, !check.materializing {
                check.materializing = true
                materialize(key, path: file.path)
            }
            backOff(&check)
            pending[key] = check
        case .arrive:
            // The settle delay gives a watched folder a file moved out of it time to hand it over.
            if let departure = options.ledger.claim(
                key, size: info.size, modified: info.modified, created: info.birth, now: now
            ) {
                setStatus(departure.status, for: key, now: now)
            } else {
                setStatus(.emitted(at: now), for: key, now: now)
                onNewMediaFile(URL(fileURLWithPath: file.path))
            }
        }
    }

    /// Off the actor, since the read waits for the download; a failed read hands the file over as it is.
    private func materialize(_ key: FileKey, path: String) {
        let cloud = options.cloud
        Self.placeholderReads.addOperation { [weak self] in
            let result = Result { try cloud.materialize(path) }
            Task { await self?.materialized(key, path: path, result: result) }
        }
    }

    /// Two at a time, apart from the scans: each read can wait minutes on a download.
    private static let placeholderReads: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "app.parola.folder-watch.placeholder-reads"
        queue.maxConcurrentOperationCount = 2
        queue.qualityOfService = .utility
        return queue
    }()

    private func materialized(_ key: FileKey, path: String, result: Result<Void, any Error>) {
        guard files[key]?.path == path, files[key]?.status == .pending else { return }
        switch result {
        case .success:
            pending[key]?.dueTick = currentTick + 1
            pending[key]?.backoff = 1
            scheduleSettleTick()
        case .failure(let error):
            ParolaLog.error(.library, "a watched cloud file never downloaded; handing it over as it is", [.error: .error(error)])
            let now = options.clock.now()
            setStatus(.emitted(at: now), for: key, now: now)
            publishBaselineChange()
            onNewMediaFile(URL(fileURLWithPath: path))
        }
    }

    private func backOff(_ check: inout PendingCheck) {
        check.dueTick = currentTick + check.backoff + 1
        check.backoff = min(check.backoff * 2, Self.longestBackoff)
    }

    private func recheckEmitted(_ key: FileKey, now: Date) {
        guard let file = files[key], case .emitted(let at) = file.status,
              now < at.addingTimeInterval(Self.seconds(options.reemitWindow)) else {
            watchedAfterEmit.remove(key)
            return
        }
        guard let info = FileInfo(file.path), info.size != file.size || info.modified != file.modified else { return }
        files[key]?.size = info.size
        files[key]?.modified = info.modified
        baselineChanged = true
        if arrivesAgain(modified: info.modified, emittedAt: at) {
            setStatus(.pending, for: key, now: now)
        }
    }

    struct SettleObservation: Equatable {
        var size: Int64
        var modified: Date
        var created: Date
        var isDataless: Bool
    }

    enum SettleVerdict: Equatable {
        case wait
        /// Nothing will change until someone else acts: Finder finishing a copy, a writer adding bytes.
        case hold
        case download
        case arrive
    }

    /// Finder dates a file it is still copying 14 February 1946.
    static let finderBusyDays = Date(timeIntervalSince1970: -753_667_200)...Date(timeIntervalSince1970: -753_494_400)

    /// `stableChecks` unchanged non-empty checks and a date older than one interval; placeholders and Finder copies wait.
    static func settle(
        _ observation: SettleObservation,
        after previous: (size: Int64, modified: Date),
        checks: inout Int,
        now: Date,
        options: Options
    ) -> SettleVerdict {
        guard !observation.isDataless else {
            checks = 0
            return .download
        }
        guard observation.size > 0, !finderBusyDays.contains(observation.created) else {
            checks = 0
            return .hold
        }
        checks = observation.size == previous.size && observation.modified == previous.modified ? checks + 1 : 1
        let cutoff = now.addingTimeInterval(-seconds(options.settledInterval))
        return checks >= options.stableChecks && observation.modified <= cutoff ? .arrive : .wait
    }

    private static func seconds(_ duration: Duration) -> Double {
        let comp = duration.components
        return Double(comp.seconds) + Double(comp.attoseconds) / 1e18
    }

    /// GCD, not `Task.detached`: a detached job resuming actor work around the enumerator's
    /// NSURL bridging has crashed with EXC_ARM_DA_ALIGN before.
    private func scanOffActor(_ request: ScanRequest) async -> ScanResult {
        let queue = options.scanQueue
        return await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: Self.scan(request))
            }
        }
    }

    private static func parent(of path: String) -> String {
        (path as NSString).deletingLastPathComponent
    }

    private func resolveRootOffActor() async -> String {
        let url = folderURL
        let queue = options.scanQueue
        return await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: Self.realPath(url))
            }
        }
    }

    private static func realPath(_ url: URL) -> String {
        guard let resolved = realpath(url.path, nil) else { return url.standardizedFileURL.path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    internal var pendingPaths: Set<String> {
        Set(pending.keys.compactMap { files[$0]?.path })
    }

    internal var trackedPaths: Set<String> {
        Set(files.values.map(\.path))
    }

    internal var sourcelessDirectories: Set<String> {
        unsourced
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
