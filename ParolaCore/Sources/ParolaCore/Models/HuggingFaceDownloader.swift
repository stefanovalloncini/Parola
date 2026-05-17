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
        progress: (@Sendable (Double) -> Void)?
    ) async throws {
        let files = try await listFiles(repo: repo, path: subpath, revision: revision)
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
                (tmp, response) = try await URLSession.shared.download(from: fileURL, delegate: delegate)
            } catch is CancellationError {
                try? sidecar.write(to: sidecarURL)
                throw CancellationError()
            }
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw ParolaError.modelDownloadFailed(
                    repo,
                    underlying: "HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1) for \(entry.path)"
                )
            }
            if FileManager.default.fileExists(atPath: localURL.path) {
                try? FileManager.default.removeItem(at: localURL)
            }
            try FileManager.default.moveItem(at: tmp, to: localURL)

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
        prefixToStrip: String? = nil
    ) async throws -> [ListedFile] {
        try Task.checkCancellation()
        let basePath = path.map { $0.hasSuffix("/") ? String($0.dropLast()) : $0 } ?? ""
        let strip = prefixToStrip ?? basePath
        let endpoint = makeTreeURL(repo: repo, path: basePath, revision: revision)

        var request = URLRequest(url: endpoint)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw ParolaError.modelDownloadFailed(repo, underlying: "Tree HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)")
        }
        let entries = try JSONDecoder().decode([TreeEntry].self, from: data)

        var result: [ListedFile] = []
        for entry in entries {
            switch entry.type {
            case "file":
                let relative = entry.path
                    .deletingPathPrefix(strip.isEmpty ? "" : strip + "/")
                result.append(ListedFile(
                    path: entry.path,
                    relativeName: relative,
                    size: entry.size,
                    expectedSHA256: entry.lfs.flatMap(extractSHA256)
                ))
            case "directory":
                let sub = try await listFiles(
                    repo: repo,
                    path: entry.path,
                    revision: revision,
                    prefixToStrip: strip
                )
                result.append(contentsOf: sub)
            default:
                continue
            }
        }
        return result
    }

    private static func extractSHA256(from lfs: LFSMeta) -> String? {
        let prefix = "sha256:"
        guard lfs.oid.hasPrefix(prefix) else { return nil }
        return String(lfs.oid.dropFirst(prefix.count))
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

    private static func sha256Hex(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        let chunkSize = 1 << 20
        while true {
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
