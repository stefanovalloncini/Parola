import Foundation

extension FolderWatcher {
    struct ScannedFile: Sendable {
        var key: FileKey
        var path: String
        var size: Int64
        var modified: Date
        var created: Date?
    }

    /// Subdirectories carry their inode, so a folder replaced under the same name is noticed.
    struct Listing: Sendable {
        var path: String
        var inode: UInt64?
        /// Read before the children: a later date means the listing may have missed a change.
        var modified: Date?
        var media: [ScannedFile] = []
        var subdirectories: [String: FileKey] = [:]
    }

    enum ListOutcome: Sendable {
        case listed(Listing)
        case missing
        /// Out of descriptors or interrupted: the directory is still there, try again.
        case failed
    }

    typealias Lister = @Sendable (_ path: String, _ recursive: Bool) -> ListOutcome

    struct ScanRequest: Sendable {
        /// Parents before children, so a subtree dropped by its parent's listing is rebuilt after it.
        var directories: [String]
        /// Directories never listed, walked whole.
        var walks: [String] = []
        var knownSubdirectories: [String: [String: FileKey]]
        var recursive: Bool
        var lister: Lister
    }

    struct ScanResult: Sendable {
        var listings: [Listing] = []
        var missing: Set<String> = []
        var failed: Set<String> = []
    }

    /// Lists each directory one level deep and walks only the subdirectories new to it.
    static func scan(_ request: ScanRequest) -> ScanResult {
        var result = ScanResult()
        for path in request.directories {
            switch request.lister(path, request.recursive) {
            case .missing:
                result.missing.insert(path)
            case .failed:
                result.failed.insert(path)
            case .listed(let listing):
                result.listings.append(listing)
                let known = request.knownSubdirectories[path] ?? [:]
                for (child, key) in listing.subdirectories.sorted(by: { $0.key < $1.key }) where known[child] != key {
                    walk(child, request: request, into: &result)
                }
            }
        }
        for root in request.walks {
            walk(root, request: request, into: &result)
        }
        return result
    }

    static func walk(_ root: String, request: ScanRequest, into result: inout ScanResult) {
        var queue = [root]
        var next = 0
        while next < queue.count {
            let path = queue[next]
            next += 1
            switch request.lister(path, request.recursive) {
            case .missing:
                result.missing.insert(path)
            case .failed:
                result.failed.insert(path)
            case .listed(let listing):
                result.listings.append(listing)
                queue.append(contentsOf: listing.subdirectories.keys.sorted())
            }
        }
    }

    /// `readdir`, and `lstat` only for media and directories: most entries in a big tree are neither.
    static func list(_ path: String, recursive: Bool) -> ListOutcome {
        let info = FileInfo(path)
        guard let directory = opendir(path) else {
            return [EMFILE, ENFILE, EINTR, EAGAIN, ENOMEM].contains(errno) ? .failed : .missing
        }
        defer { closedir(directory) }
        var listing = Listing(path: path, inode: info?.inode, modified: info?.modified)
        let prefix = path.hasSuffix("/") ? path : path + "/"
        while let entry = readdir(directory) {
            let name = withUnsafeBytes(of: entry.pointee.d_name) { bytes in
                String(decoding: bytes.prefix(Int(entry.pointee.d_namlen)), as: UTF8.self)
            }
            guard !name.hasPrefix(".") else { continue }
            let isMedia = isMediaFile(name: name)
            let type = Int32(entry.pointee.d_type)
            if type == DT_REG && !isMedia { continue }
            if type == DT_DIR && !recursive { continue }
            let childPath = prefix + name
            guard let info = FileInfo(childPath), !info.isHidden else { continue }
            if info.isDirectory {
                if recursive, !isPackage(childPath, name: name) {
                    listing.subdirectories[childPath] = FileKey(inode: info.inode)
                }
            } else if info.isRegularFile, isMedia {
                listing.media.append(ScannedFile(
                    key: FileKey(inode: info.inode),
                    path: childPath,
                    size: info.size,
                    modified: info.modified,
                    created: info.birth
                ))
            }
        }
        return .listed(listing)
    }

    static func isMediaFile(name: String) -> Bool {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return false }
        let ext = name[name.index(after: dot)...].lowercased()
        return audioExtensions.contains(ext) || videoExtensions.contains(ext)
    }

    /// A package (an app, a `.parola` document, a library) is one item to the user, never a folder to watch.
    private static func isPackage(_ path: String, name: String) -> Bool {
        guard name.contains(".") else { return false }
        return (try? URL(fileURLWithPath: path, isDirectory: true).resourceValues(forKeys: [.isPackageKey]))?.isPackage == true
    }

    /// One conversion of `lstat`'s dates everywhere, so a listing and a later check compare exactly.
    struct FileInfo: Sendable {
        var inode: UInt64
        var size: Int64
        var modified: Date
        var created: Date
        var flags: UInt32
        var mode: mode_t

        init?(_ path: String) {
            var info = stat()
            guard lstat(path, &info) == 0 else { return nil }
            inode = UInt64(info.st_ino)
            size = Int64(info.st_size)
            modified = Self.date(info.st_mtimespec)
            created = Self.date(info.st_birthtimespec)
            flags = info.st_flags
            mode = info.st_mode
        }

        /// The birth time, or nil where the volume keeps none or Finder has parked it on its busy date.
        var birth: Date? {
            created == Date(timeIntervalSince1970: 0) || FolderWatcher.finderBusyDays.contains(created) ? nil : created
        }

        var isDirectory: Bool { mode & S_IFMT == S_IFDIR }
        var isRegularFile: Bool { mode & S_IFMT == S_IFREG }
        var isHidden: Bool { flags & UInt32(UF_HIDDEN) != 0 }
        /// A cloud file whose bytes are still on the server.
        var isDataless: Bool { flags & UInt32(SF_DATALESS) != 0 }

        private static func date(_ time: timespec) -> Date {
            Date(timeIntervalSince1970: TimeInterval(time.tv_sec) + TimeInterval(time.tv_nsec) / 1_000_000_000)
        }
    }
}
