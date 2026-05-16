import Foundation

public actor FolderWatcher {
    public static let audioExtensions: Set<String> = ["mp3", "wav", "m4a", "aac", "flac", "aif", "aiff", "caf", "opus", "ogg"]
    public static let videoExtensions: Set<String> = ["mp4", "mov", "m4v", "webm", "mkv", "avi", "wmv"]

    public static func isMediaFile(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return audioExtensions.contains(ext) || videoExtensions.contains(ext)
    }

    private let folderURL: URL
    private let onNewMediaFile: @Sendable (URL) -> Void
    private var fileDescriptor: Int32 = -1
    private var source: DispatchSourceFileSystemObject?
    private var knownFiles: Set<String> = []
    private var scanTask: Task<Void, Never>?
    private var scanContinuation: AsyncStream<Void>.Continuation?

    public init(folderURL: URL, onNewMediaFile: @escaping @Sendable (URL) -> Void) {
        self.folderURL = folderURL
        self.onNewMediaFile = onNewMediaFile
    }

    deinit {
        scanContinuation?.finish()
        scanTask?.cancel()
        source?.cancel()
    }

    public func start() {
        guard source == nil else { return }
        let fd = folderURL.path.withCString { open($0, O_EVTONLY) }
        guard fd >= 0 else { return }
        fileDescriptor = fd
        knownFiles = scanFolder()

        let (stream, continuation) = AsyncStream.makeStream(of: Void.self)
        scanContinuation = continuation
        scanTask = Task { [weak self] in
            for await _ in stream {
                await self?.checkForNewFiles()
            }
        }

        let queue = DispatchQueue(label: "com.parola.folder-watch.\(UUID().uuidString)")
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
        source = src
    }

    public func stop() {
        source?.cancel()
        source = nil
        fileDescriptor = -1
        scanContinuation?.finish()
        scanContinuation = nil
        scanTask?.cancel()
        scanTask = nil
    }

    private func checkForNewFiles() {
        let current = scanFolder()
        let added = current.subtracting(knownFiles)
        knownFiles = current
        for path in added {
            let url = URL(fileURLWithPath: path)
            if Self.isMediaFile(url) {
                onNewMediaFile(url)
            }
        }
    }

    private func scanFolder() -> Set<String> {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(atPath: folderURL.path) else { return [] }
        return Set(contents.map { folderURL.appendingPathComponent($0).path })
    }
}
