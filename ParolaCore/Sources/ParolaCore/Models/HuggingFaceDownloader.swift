import CryptoKit
import Foundation

/// Minimal HuggingFace snapshot downloader for non-WhisperKit engines.
/// Fetches the file tree for a public repo, downloads each file with a per-file
/// progress aggregate, and writes to `destination/<filename>`.
enum HuggingFaceDownloader {
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

        let totalBytes = files.reduce(Int64(0)) { $0 + ($1.size ?? 0) }
        var downloadedBytes: Int64 = 0

        for entry in files {
            let fileURL = try resolveURL(repo: repo, path: entry.path, revision: revision)
            let localURL = destination.appendingPathComponent(entry.relativeName)
            try FileManager.default.createDirectory(
                at: localURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let (tmp, response) = try await URLSession.shared.download(from: fileURL)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw ParolaError.modelDownloadFailed(repo, underlying: "HTTP \( (response as? HTTPURLResponse)?.statusCode ?? -1) for \(entry.path)")
            }
            if FileManager.default.fileExists(atPath: localURL.path) {
                try? FileManager.default.removeItem(at: localURL)
            }
            try FileManager.default.moveItem(at: tmp, to: localURL)

            if let expected = entry.expectedSHA256 {
                let actual = try sha256Hex(of: localURL)
                if actual.caseInsensitiveCompare(expected) != .orderedSame {
                    try? FileManager.default.removeItem(at: localURL)
                    throw ParolaError.modelChecksumMismatch(
                        file: entry.relativeName,
                        expected: expected,
                        got: actual
                    )
                }
            }

            let size = entry.size ?? (try? FileManager.default.attributesOfItem(atPath: localURL.path)[.size] as? Int64) ?? 0
            downloadedBytes += size
            if totalBytes > 0 {
                progress?(min(1.0, Double(downloadedBytes) / Double(totalBytes)))
            }
        }
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

private extension String {
    func deletingPathPrefix(_ prefix: String) -> String {
        guard !prefix.isEmpty, hasPrefix(prefix) else { return self }
        return String(dropFirst(prefix.count))
    }
}
