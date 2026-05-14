import Foundation
import WhisperKit

/// Manages the on-disk cache of WhisperKit Core ML models.
///
/// Both the macOS app and the CLI use the same cache directory so a model
/// downloaded by either is visible to the other.
///
/// State is immutable after init, so the type is `Sendable` without actor isolation.
public final class ModelStore: Sendable {
    public static let shared = ModelStore()

    private let modelsDirectory: URL

    public init(modelsDirectory: URL? = nil) {
        if let dir = modelsDirectory {
            self.modelsDirectory = dir
        } else {
            let appSupport = FileManager.default
                .urls(for: .applicationSupportDirectory, in: .userDomainMask)
                .first!
                .appendingPathComponent("Parola", isDirectory: true)
                .appendingPathComponent("Models", isDirectory: true)
            self.modelsDirectory = appSupport
        }
        try? FileManager.default.createDirectory(at: self.modelsDirectory, withIntermediateDirectories: true)
    }

    public var directory: URL { modelsDirectory }

    /// WhisperKit downloads into `<downloadBase>/models/argmaxinc/whisperkit-coreml/<variant>/`.
    /// This computes that canonical path.
    public func installedURL(for variant: String, repo: String = "argmaxinc/whisperkit-coreml") -> URL {
        modelsDirectory
            .appendingPathComponent("models", isDirectory: true)
            .appendingPathComponent(repo, isDirectory: true)
            .appendingPathComponent(variant, isDirectory: true)
    }

    /// Returns the curated catalog merged with what's actually on disk.
    public func catalog() -> [ModelInfo] {
        ModelInfo.defaultCatalog.map { entry in
            let url = installedURL(for: entry.name)
            let installed = FileManager.default.fileExists(atPath: url.path)
            var copy = entry
            copy.isInstalled = installed
            copy.installedURL = installed ? url : nil
            return copy
        }
    }

    /// Returns models present on disk, even if not in the curated catalog.
    public func installedModels() throws -> [ModelInfo] {
        let fm = FileManager.default
        let repoDir = modelsDirectory
            .appendingPathComponent("models/argmaxinc/whisperkit-coreml", isDirectory: true)
        guard fm.fileExists(atPath: repoDir.path) else { return [] }
        let entries = (try? fm.contentsOfDirectory(at: repoDir, includingPropertiesForKeys: nil)) ?? []
        let catalog = ModelInfo.defaultCatalog
        return entries
            .filter { $0.lastPathComponent.hasPrefix(".") == false }
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .map { url in
                if let known = catalog.first(where: { $0.name == url.lastPathComponent }) {
                    var copy = known
                    copy.isInstalled = true
                    copy.installedURL = url
                    return copy
                }
                return ModelInfo(
                    name: url.lastPathComponent,
                    label: url.lastPathComponent,
                    approximateSizeBytes: directorySize(url),
                    isMultilingual: !url.lastPathComponent.hasSuffix(".en"),
                    isInstalled: true,
                    installedURL: url
                )
            }
            .sorted { $0.name < $1.name }
    }

    public func isInstalled(_ variant: String) -> Bool {
        FileManager.default.fileExists(atPath: installedURL(for: variant).path)
    }

    /// Downloads a model variant into our cache directory. If already present, returns immediately.
    /// - Parameter progress: 0.0–1.0 progress callback (best-effort).
    public func download(
        variant: String,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> URL {
        if isInstalled(variant) {
            progress?(1.0)
            return installedURL(for: variant)
        }
        do {
            let url = try await WhisperKit.download(
                variant: variant,
                downloadBase: modelsDirectory,
                useBackgroundSession: false,
                progressCallback: { p in
                    progress?(p.fractionCompleted)
                }
            )
            return url
        } catch {
            throw ParolaError.modelDownloadFailed(variant, underlying: String(describing: error))
        }
    }

    public func delete(variant: String) throws {
        let url = installedURL(for: variant)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ParolaError.modelNotFound(variant)
        }
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            throw ParolaError.ioError("Failed to delete \(variant): \(error.localizedDescription)")
        }
    }

    public func sizeOnDisk(_ variant: String) -> Int? {
        let url = installedURL(for: variant)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return directorySize(url)
    }

    private func directorySize(_ url: URL) -> Int? {
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .fileSizeKey]
        ) else { return nil }
        var total = 0
        for case let fileURL as URL in enumerator {
            if let values = try? fileURL.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileSizeKey]) {
                total += values.totalFileAllocatedSize ?? values.fileSize ?? 0
            }
        }
        return total
    }
}
