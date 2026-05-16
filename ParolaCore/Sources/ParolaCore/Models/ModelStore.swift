import Foundation
import WhisperKit

/// Manages the on-disk cache of transcription models.
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

    /// Returns the on-disk path for a model variant. Looks up the catalog to find the
    /// canonical repo + subpath; falls back to the legacy WhisperKit path for unknown variants.
    public func installedURL(for variant: String) -> URL {
        if let entry = ModelCatalog.variant(id: variant) {
            return installedURL(for: entry.downloadSource)
        }
        return installedURL(for: ModelDownloadSource(
            huggingFaceRepo: "argmaxinc/whisperkit-coreml",
            subpath: variant
        ))
    }

    public func installedURL(for source: ModelDownloadSource) -> URL {
        var url = modelsDirectory
            .appendingPathComponent("models", isDirectory: true)
            .appendingPathComponent(source.huggingFaceRepo, isDirectory: true)
        if !source.subpath.isEmpty {
            url = url.appendingPathComponent(source.subpath, isDirectory: true)
        }
        return url
    }

    /// Returns the curated catalog merged with what's actually on disk.
    /// Filters by the managed-config engine allowlist if one is set.
    public func catalog() -> [ModelInfo] {
        ManagedConfiguration.shared.filterAllowed(ModelCatalog.all).map { variant in
            let url = installedURL(for: variant.downloadSource)
            let installed = FileManager.default.fileExists(atPath: url.path)
            return ModelInfo(
                name: variant.id,
                label: variant.displayName,
                approximateSizeBytes: Int(variant.sizeBytes),
                isMultilingual: variant.languageScope == nil,
                isInstalled: installed,
                installedURL: installed ? url : nil
            )
        }
    }

    /// Returns models present on disk, even if not in the curated catalog.
    public func installedModels() throws -> [ModelInfo] {
        let fm = FileManager.default
        var seen: [String: ModelInfo] = [:]

        for variant in ModelCatalog.all {
            let url = installedURL(for: variant.downloadSource)
            if fm.fileExists(atPath: url.path) {
                seen[variant.id] = ModelInfo(
                    name: variant.id,
                    label: variant.displayName,
                    approximateSizeBytes: Int(variant.sizeBytes),
                    isMultilingual: variant.languageScope == nil,
                    isInstalled: true,
                    installedURL: url
                )
            }
        }

        let legacyRepoDir = modelsDirectory
            .appendingPathComponent("models/argmaxinc/whisperkit-coreml", isDirectory: true)
        if fm.fileExists(atPath: legacyRepoDir.path) {
            let entries = (try? fm.contentsOfDirectory(at: legacyRepoDir, includingPropertiesForKeys: nil)) ?? []
            for url in entries
                where !url.lastPathComponent.hasPrefix(".")
                && (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                let id = url.lastPathComponent
                if seen[id] == nil {
                    seen[id] = ModelInfo(
                        name: id,
                        label: id,
                        approximateSizeBytes: directorySize(url),
                        isMultilingual: !id.hasSuffix(".en"),
                        isInstalled: true,
                        installedURL: url
                    )
                }
            }
        }

        return seen.values.sorted { $0.name < $1.name }
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
        guard let entry = ModelCatalog.variant(id: variant) else {
            return try await downloadViaWhisperKit(variant: variant, progress: progress)
        }
        switch entry.engineID {
        case .whisperKit:
            return try await downloadViaWhisperKit(variant: variant, progress: progress)
        case .parakeet:
            return try await downloadViaHuggingFace(source: entry.downloadSource, progress: progress)
        default:
            return try await downloadViaHuggingFace(source: entry.downloadSource, progress: progress)
        }
    }

    private func downloadViaWhisperKit(
        variant: String,
        progress: (@Sendable (Double) -> Void)?
    ) async throws -> URL {
        do {
            return try await WhisperKit.download(
                variant: variant,
                downloadBase: modelsDirectory,
                useBackgroundSession: false,
                progressCallback: { p in progress?(p.fractionCompleted) }
            )
        } catch {
            throw ParolaError.modelDownloadFailed(variant, underlying: String(describing: error))
        }
    }

    private func downloadViaHuggingFace(
        source: ModelDownloadSource,
        progress: (@Sendable (Double) -> Void)?
    ) async throws -> URL {
        let destination = installedURL(for: source)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        do {
            try await HuggingFaceDownloader.snapshot(
                repo: source.huggingFaceRepo,
                subpath: source.subpath.isEmpty ? nil : source.subpath,
                destination: destination,
                progress: progress
            )
            progress?(1.0)
            return destination
        } catch {
            throw ParolaError.modelDownloadFailed(source.huggingFaceRepo, underlying: String(describing: error))
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
