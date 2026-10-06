import CryptoKit
import Foundation

/// Minimal HuggingFace snapshot downloader for non-WhisperKit engines.
/// Fetches the file tree for a public repo, downloads each file with a per-file
/// progress aggregate, and writes to `destination/<filename>`. Cancellation tears down
/// the current request; partial state lives in a `.parola-download.json` sidecar so
/// the next attempt can resume.
package enum HuggingFaceDownloader {
    package static let sidecarFilename = ".parola-download.json"
    static let revisionFilename = ".parola-revision"

    package static func snapshot(
        repo: String,
        subpath: String?,
        destination: URL,
        revision: String = "main",
        urlSession: URLSession = .shared,
        progress: (@Sendable (Double) -> Void)?
    ) async throws {
        let files = try await listFiles(repo: repo, path: subpath, revision: revision, urlSession: urlSession)
        guard !files.isEmpty else {
            ParolaLog.error(.models, "repo listing was empty")
            throw ParolaError.modelDownloadFailed(repo, underlying: "No files listed for repo")
        }

        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let sidecarURL = destination.appendingPathComponent(sidecarFilename)
        try await fetch(
            files,
            repo: repo,
            revision: revision,
            into: destination,
            sidecar: resumableSidecar(at: sidecarURL, in: destination, repo: repo, revision: revision),
            urlSession: urlSession,
            progress: progress
        )
        try? FileManager.default.removeItem(at: sidecarURL)
    }

    /// Downloads the files of `repo` at commit `revision` that `include` names (a subtree when an entry ends in "/", else one file) to their repo paths under `destination`, then marks it with the revision.
    package static func snapshot(
        repo: String,
        revision: String,
        include: [String],
        to destination: URL,
        urlSession: URLSession = .shared,
        progress: (@Sendable (Double) -> Void)?
    ) async throws {
        guard isCommitHash(revision) else {
            throw ParolaError.modelDownloadFailed(repo, underlying: "Revision \(revision) is not a commit hash")
        }
        guard !include.isEmpty else {
            throw ParolaError.modelDownloadFailed(repo, underlying: "Nothing to include")
        }
        if let bad = include.first(where: { !isPlainRepoPath($0) }) {
            throw ParolaError.modelDownloadFailed(repo, underlying: "Bad include path \(bad)")
        }
        let progress = progress.map(DownloadProgressGate.gating)
        do {
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            let sidecarURL = destination.appendingPathComponent(sidecarFilename)
            let sidecar = resumableSidecar(at: sidecarURL, in: destination, repo: repo, revision: revision)
            try sidecar.write(to: sidecarURL)
            let markerURL = destination.appendingPathComponent(revisionFilename)
            if FileManager.default.fileExists(atPath: markerURL.path) {
                try FileManager.default.removeItem(at: markerURL)
            }
            let listed = try await listFiles(repo: repo, path: nil, revision: revision, urlSession: urlSession)
            try await fetch(
                included(listed, by: include, repo: repo, revision: revision),
                repo: repo,
                revision: revision,
                into: destination,
                sidecar: sidecar,
                urlSession: urlSession,
                progress: progress
            )
            try Data(revision.utf8).write(to: markerURL, options: .atomic)
            try? FileManager.default.removeItem(at: sidecarURL)
            progress?(1.0)
        } catch let error where isCancellation(error) {
            throw CancellationError()
        }
    }

    /// The revision a finished include-list download left at `destination`; nil while one is unfinished or none ever finished.
    package static func installedRevision(at destination: URL) -> String? {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: destination.appendingPathComponent(sidecarFilename).path),
              let data = fm.contents(atPath: destination.appendingPathComponent(revisionFilename).path),
              let revision = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !revision.isEmpty
        else { return nil }
        return revision
    }

    /// A sidecar left by another revision is dropped with the files it recorded, so a pin bump never resumes into a mixed install.
    private static func resumableSidecar(
        at url: URL,
        in destination: URL,
        repo: String,
        revision: String
    ) -> DownloadSidecar {
        let fresh = DownloadSidecar(repo: repo, revision: revision, files: [:])
        guard let existing = try? DownloadSidecar.read(at: url) else { return fresh }
        guard existing.revision != revision else { return existing }
        for name in existing.files.keys where isPlainRepoPath(name) {
            try? FileManager.default.removeItem(at: destination.appendingPathComponent(name))
        }
        return fresh
    }

    private static func fetch(
        _ files: [ListedFile],
        repo: String,
        revision: String,
        into destination: URL,
        sidecar: DownloadSidecar,
        urlSession: URLSession,
        progress: (@Sendable (Double) -> Void)?
    ) async throws {
        var sidecar = sidecar
        let sidecarURL = destination.appendingPathComponent(sidecarFilename)
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
            } catch let error where isCancellation(error) {
                try? sidecar.write(to: sidecarURL)
                throw CancellationError()
            }
            let httpStatus = (response as? HTTPURLResponse)?.statusCode
            guard let httpStatus, (200..<300).contains(httpStatus) else {
                ParolaLog.error(
                    .models,
                    "file download returned HTTP \(httpStatus ?? -1)",
                    [.count: .int(sidecar.files.values.filter(\.complete).count)]
                )
                throw ParolaError.modelDownloadFailed(
                    repo,
                    underlying: "HTTP \(httpStatus ?? -1) for \(entry.path)"
                )
            }
            try Self.install(from: tmp, to: localURL)

            if let expected = entry.expectedSHA256 {
                let actual = try sha256Hex(of: localURL)
                if actual.caseInsensitiveCompare(expected) != .orderedSame {
                    ParolaLog.fault(
                        .models,
                        "checksum mismatch, file discarded",
                        [.bytes: .bytes(fileSize(at: localURL))]
                    )
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
                    ParolaLog.error(.models, "short file rejected", [.bytes: .bytes(actual)])
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
    }

    private static func included(
        _ files: [ListedFile],
        by include: [String],
        repo: String,
        revision: String
    ) throws -> [ListedFile] {
        let candidates = files.filter { isPlainRepoPath($0.path) }
        for item in include where !candidates.contains(where: { matches($0.path, item) }) {
            ParolaLog.error(.models, "include path matched no file in the listing")
            throw ParolaError.modelDownloadFailed(repo, underlying: "No \(item) at revision \(revision)")
        }
        return candidates.filter { file in include.contains { matches(file.path, $0) } }
    }

    private static func matches(_ path: String, _ item: String) -> Bool {
        item.hasSuffix("/") ? path.hasPrefix(item) : path == item
    }

    private static func isPlainRepoPath(_ path: String) -> Bool {
        let trimmed = path.hasSuffix("/") ? path.dropLast() : Substring(path)
        guard !trimmed.isEmpty else { return false }
        return trimmed.split(separator: "/", omittingEmptySubsequences: false)
            .allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    private static func isCommitHash(_ revision: String) -> Bool {
        revision.count == 40 && revision.allSatisfy { $0.isASCII && $0.isHexDigit }
    }

    private static func fileSize(at url: URL) -> Int64 {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
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
        let basePath = path.map { $0.hasSuffix("/") ? String($0.dropLast()) : $0 } ?? ""
        let endpoint = makeTreeURL(repo: repo, path: basePath, revision: revision)

        var entries: [TreeEntry] = []
        var cursor: String?
        var seenCursors: Set<String> = []
        repeat {
            try Task.checkCancellation()
            guard let page = treePageURL(endpoint, cursor: cursor) else {
                throw ParolaError.modelDownloadFailed(repo, underlying: "Bad tree page cursor")
            }
            var request = URLRequest(url: page)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            let (data, response) = try await urlSession.data(for: request)
            let httpStatus = (response as? HTTPURLResponse)?.statusCode
            guard let httpStatus, (200..<300).contains(httpStatus) else {
                throw ParolaError.modelDownloadFailed(repo, underlying: "Tree HTTP \(httpStatus ?? -1)")
            }
            entries += try JSONDecoder().decode([TreeEntry].self, from: data)
            cursor = try nextPageCursor(of: response, repo: repo)
            if let cursor, !seenCursors.insert(cursor).inserted {
                throw ParolaError.modelDownloadFailed(repo, underlying: "Tree listing repeats a page")
            }
        } while cursor != nil

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

    private static func treePageURL(_ endpoint: URL, cursor: String?) -> URL? {
        guard let cursor else { return endpoint }
        return URL(string: endpoint.absoluteString + "&cursor=" + cursor)
    }

    /// The tree API pages a long listing through a `Link: <…&cursor=…>; rel="next"` header.
    private static func nextPageCursor(of response: URLResponse, repo: String) throws -> String? {
        guard let links = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Link"),
              let next = links.split(separator: ",").first(where: {
                  $0.replacingOccurrences(of: "\"", with: "").contains("rel=next")
              })
        else { return nil }
        let target = next.drop { $0 != "<" }.dropFirst().prefix { $0 != ">" }
        guard let cursor = URLComponents(string: String(target))?
            .percentEncodedQueryItems?.first(where: { $0.name == "cursor" })?.value,
            !cursor.isEmpty
        else {
            throw ParolaError.modelDownloadFailed(repo, underlying: "Tree listing has a next page without a cursor")
        }
        return cursor
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

package struct DownloadSidecar: Codable, Equatable, Sendable {
    package struct FileRecord: Codable, Equatable, Sendable {
        package var size: Int64
        package var sha256: String?
        package var complete: Bool

        package init(size: Int64, sha256: String?, complete: Bool) {
            self.size = size
            self.sha256 = sha256
            self.complete = complete
        }
    }

    package var repo: String
    package var revision: String
    package var files: [String: FileRecord]

    package init(repo: String, revision: String, files: [String: FileRecord]) {
        self.repo = repo
        self.revision = revision
        self.files = files
    }

    package static func read(at url: URL) throws -> DownloadSidecar {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(DownloadSidecar.self, from: data)
    }

    package func write(to url: URL) throws {
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
