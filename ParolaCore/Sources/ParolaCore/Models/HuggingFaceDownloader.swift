import CryptoKit
import Foundation

/// Minimal HuggingFace snapshot downloader for non-WhisperKit engines.
/// Fetches the file tree for a public repo, downloads each file with a per-file
/// progress aggregate, and writes to `destination/<filename>`. Cancellation tears down
/// the current request; partial state lives in a `.parola-download.json` sidecar so
/// the next attempt can resume.
enum HuggingFaceDownloader {
    static let sidecarFilename = ".parola-download.json"

    static func snapshot(
        repo: String,
        subpath: String?,
        destination: URL,
        revision: String = "main",
        urlSession: URLSession = .shared,
        progress: (@Sendable (Double) -> Void)?
    ) async throws {
        let files = try await listFiles(repo: repo, path: subpath, revision: revision, urlSession: urlSession)
        guard !files.isEmpty else {
            throw ParolaError.modelDownloadFailed(repo, underlying: "No files listed for repo")
        }

        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let sidecarURL = destination.appendingPathComponent(sidecarFilename)
        var sidecar = (try? DownloadSidecar.read(at: sidecarURL)) ?? DownloadSidecar(
            repo: repo,
            revision: revision,
            files: [:]
        )

        let totalBytes = files.reduce(Int64(0)) { $0 + ($1.size ?? 0) }
        var downloadedBytes = files.reduce(Int64(0)) { acc, entry in
            sidecar.files[entry.relativeName]?.complete == true ? acc + (entry.size ?? 0) : acc
        }
        if totalBytes > 0 {
            progress?(min(1.0, Double(downloadedBytes) / Double(totalBytes)))
        }

        for entry in files {
            try Task.checkCancellation()

            let localURL = destination.appendingPathComponent(entry.relativeName)
            if let record = sidecar.files[entry.relativeName],
               record.complete,
               FileManager.default.fileExists(atPath: localURL.path) {
                continue
            }

            try FileManager.default.createDirectory(
                at: localURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )

            let baseDone = downloadedBytes
            let delegate = ProgressTrackingDelegate { written in
                guard totalBytes > 0 else { return }
                let total = baseDone + written
                progress?(min(1.0, Double(total) / Double(totalBytes)))
            }

            let fileURL = try resolveURL(repo: repo, path: entry.path, revision: revision)
            let (tmp, response): (URL, URLResponse)
            do {
                (tmp, response) = try await urlSession.download(from: fileURL, delegate: delegate)
            } catch is CancellationError {
                try? sidecar.write(to: sidecarURL)
                throw CancellationError()
            }
            let httpStatus = (response as? HTTPURLResponse)?.statusCode
            guard let httpStatus, (200..<300).contains(httpStatus) else {
                throw ParolaError.modelDownloadFailed(
                    repo,
                    underlying: "HTTP \(httpStatus ?? -1) for \(entry.path)"
                )
            }
            try Self.install(from: tmp, to: localURL)

            if let expected = entry.expectedSHA256 {
                let actual = try sha256Hex(of: localURL)
                if actual.caseInsensitiveCompare(expected) != .orderedSame {
                    try? FileManager.default.removeItem(at: localURL)
                    sidecar.files[entry.relativeName] = nil
                    try? sidecar.write(to: sidecarURL)
                    throw ParolaError.modelChecksumMismatch(
                        file: entry.relativeName,
                        expected: expected,
                        got: actual
                    )
                }
            } else if let expected = entry.size {
                // Non-LFS files carry no checksum, so a truncated download would otherwise be
                // recorded complete. Reject a short file and keep the sidecar so it re-fetches.
                let actual = (try? FileManager.default.attributesOfItem(atPath: localURL.path)[.size] as? Int64) ?? -1
                if actual != expected {
                    try? FileManager.default.removeItem(at: localURL)
                    sidecar.files[entry.relativeName] = nil
                    try? sidecar.write(to: sidecarURL)
                    throw ParolaError.modelDownloadFailed(
                        repo,
                        underlying: "Short file \(entry.relativeName): \(actual)/\(expected) bytes"
                    )
                }
            }

            let size = entry.size
                ?? (try? FileManager.default.attributesOfItem(atPath: localURL.path)[.size] as? Int64)
                ?? 0
            downloadedBytes += size
            sidecar.files[entry.relativeName] = .init(
                size: size,
                sha256: entry.expectedSHA256,
                complete: true
            )
            try sidecar.write(to: sidecarURL)

            if totalBytes > 0 {
                progress?(min(1.0, Double(downloadedBytes) / Double(totalBytes)))
            }
        }

        try? FileManager.default.removeItem(at: sidecarURL)
    }

    private struct LFSMeta: Decodable {
        let oid: String
    }

    private struct TreeEntry: Decodable {
        let type: String
        let path: String
        let size: Int64?
        let lfs: LFSMeta?
    }

    private struct ListedFile {
        let path: String
        let relativeName: String
        let size: Int64?
        let expectedSHA256: String?
    }

    private static func listFiles(
        repo: String,
        path: String?,
        revision: String,
        urlSession: URLSession = .shared
    ) async throws -> [ListedFile] {
        try Task.checkCancellation()
        let basePath = path.map { $0.hasSuffix("/") ? String($0.dropLast()) : $0 } ?? ""
        let endpoint = makeTreeURL(repo: repo, path: basePath, revision: revision)

        var request = URLRequest(url: endpoint)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await urlSession.data(for: request)
        let httpStatus = (response as? HTTPURLResponse)?.statusCode
        guard let httpStatus, (200..<300).contains(httpStatus) else {
            throw ParolaError.modelDownloadFailed(repo, underlying: "Tree HTTP \(httpStatus ?? -1)")
        }
        let entries = try JSONDecoder().decode([TreeEntry].self, from: data)

        // The tree request is recursive=true, so nested files are already in this listing;
        // recursing into "directory" entries would double-count every nested file.
        return entries
            .filter { $0.type == "file" }
            .map { entry in
                ListedFile(
                    path: entry.path,
                    relativeName: entry.path.deletingPathPrefix(basePath.isEmpty ? "" : basePath + "/"),
                    size: entry.size,
                    expectedSHA256: entry.lfs.flatMap(extractSHA256)
                )
            }
    }

    // The tree API serves `oid` as bare hex; older payloads carried a "sha256:" prefix.
    private static func extractSHA256(from lfs: LFSMeta) -> String? {
        let oid = lfs.oid.hasPrefix("sha256:") ? String(lfs.oid.dropFirst("sha256:".count)) : lfs.oid
        guard oid.count == 64, oid.allSatisfy(\.isHexDigit) else { return nil }
        return oid
    }

    private static func makeTreeURL(repo: String, path: String, revision: String) -> URL {
        var components = URLComponents(string: "https://huggingface.co/api/models/\(repo)/tree/\(revision)")!
        if !path.isEmpty {
            components.path += "/" + path
        }
        components.queryItems = [URLQueryItem(name: "recursive", value: "true")]
        return components.url!
    }

    private static func resolveURL(repo: String, path: String, revision: String) throws -> URL {
        guard let url = URL(string: "https://huggingface.co/\(repo)/resolve/\(revision)/\(path)") else {
            throw ParolaError.modelDownloadFailed(repo, underlying: "Bad URL for \(path)")
        }
        return url
    }

    /// Lands a freshly downloaded temp file at its destination, overwriting any prior copy.
    /// Falls back to copy+delete when `moveItem` can't rename across volumes (EXDEV), which
    /// happens when the model store is on a different volume than the system temp dir.
    static func install(from tmp: URL, to localURL: URL) throws {
        try? FileManager.default.removeItem(at: localURL)
        do {
            try FileManager.default.moveItem(at: tmp, to: localURL)
        } catch {
            try FileManager.default.copyItem(at: tmp, to: localURL)
            try? FileManager.default.removeItem(at: tmp)
        }
    }

    private static func sha256Hex(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        let chunkSize = 1 << 20
        while true {
            try Task.checkCancellation()
            let more = autoreleasepool { () -> Bool in
                let chunk = handle.readData(ofLength: chunkSize)
                guard !chunk.isEmpty else { return false }
                hasher.update(data: chunk)
                return true
            }
            if !more { break }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

struct DownloadSidecar: Codable, Equatable {
    struct FileRecord: Codable, Equatable {
        var size: Int64
        var sha256: String?
        var complete: Bool
    }

    var repo: String
    var revision: String
    var files: [String: FileRecord]

    static func read(at url: URL) throws -> DownloadSidecar {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(DownloadSidecar.self, from: data)
    }

    func write(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        try data.write(to: url, options: .atomic)
    }
}

private extension String {
    func deletingPathPrefix(_ prefix: String) -> String {
        guard !prefix.isEmpty, hasPrefix(prefix) else { return self }
        return String(dropFirst(prefix.count))
    }
}

/// Bridges `URLSessionDownloadDelegate` byte-level progress callbacks into a Swift closure.
/// Safe: single immutable `let` closure, no mutable state — `onWritten` may be called from any thread.
private final class ProgressTrackingDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let onWritten: @Sendable (Int64) -> Void

    init(onWritten: @escaping @Sendable (Int64) -> Void) {
        self.onWritten = onWritten
    }

    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        onWritten(totalBytesWritten)
    }

    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {}
}
