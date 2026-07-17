import Foundation

/// Manages the on-disk cache of transcription models.
///
/// Both the macOS app and the CLI use the same cache directory so a model
/// downloaded by either is visible to the other.
///
/// State is immutable after init, so the type is `Sendable` without actor isolation.
public final class ModelStore: Sendable {
    public static let shared = ModelStore()

    private let modelsDirectory: URL

    public static let storageOverrideKey = "parola.modelsStoragePath"

    private static let orphanScanRootRelativePaths = [
        "models/argmaxinc/whisperkit-coreml",
        "models/FluidInference",
        "models/openai",
    ]

    /// Tokenizer/config assets WhisperKit caches alongside a model. A directory holding only
    /// these (e.g. an `openai/whisper-tiny` tokenizer dir) is not a runnable model.
    private static let modelMetadataFilenames: Set<String> = [
        "config.json", "tokenizer.json", "tokenizer_config.json",
        "generation_config.json", "preprocessor_config.json",
        "special_tokens_map.json", "vocab.json", "merges.txt",
        "added_tokens.json", "normalizer.json", "readme.md",
    ]

    private var orphanScanRoots: [URL] {
        Self.orphanScanRootRelativePaths.map {
            modelsDirectory.appendingPathComponent($0, isDirectory: true)
        }
    }

    public init(modelsDirectory: URL? = nil, defaults: UserDefaults = .standard) {
        if let modelsDirectory {
            self.modelsDirectory = modelsDirectory
        } else if let raw = defaults.string(forKey: Self.storageOverrideKey),
                  !raw.trimmingCharacters(in: .whitespaces).isEmpty {
            self.modelsDirectory = URL(fileURLWithPath: (raw as NSString).expandingTildeInPath, isDirectory: true)
        } else {
            self.modelsDirectory = Self.defaultDirectory
        }
        try? FileManager.default.createDirectory(at: self.modelsDirectory, withIntermediateDirectories: true)
    }

    public static var defaultDirectory: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
            .appendingPathComponent("Parola", isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true)
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
            if variant.engineID == .appleSpeech {
                return modelInfo(for: variant, url: nil, isInstalled: true)
            }
            let url = installedURL(for: variant.downloadSource)
            let installed = isFullyDownloaded(at: url)
            return modelInfo(for: variant, url: installed ? url : nil, isInstalled: installed)
        }
    }

    /// A model directory counts as installed only when no download sidecar remains.
    /// HuggingFaceDownloader leaves that sidecar behind while a fetch is incomplete and removes it on success.
    private func isFullyDownloaded(at url: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        let sidecar = url.appendingPathComponent(HuggingFaceDownloader.sidecarFilename)
        return !FileManager.default.fileExists(atPath: sidecar.path)
    }

    /// True when an orphan directory holds something other than tokenizer/config metadata —
    /// i.e. it actually carries model weights. Hidden entries (`.cache`) are ignored.
    private func containsModelWeights(at url: URL) -> Bool {
        guard let entries = try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) else {
            return false
        }
        return entries.contains { entry in
            let name = entry.lastPathComponent
            guard !name.hasPrefix(".") else { return false }
            return !Self.modelMetadataFilenames.contains(name.lowercased())
        }
    }

    /// Returns models present on disk, even if not in the curated catalog. Includes
    /// orphan directories left by older app versions or by engine wrappers that
    /// used a different naming convention.
    public func installedModels() throws -> [ModelInfo] {
        let fm = FileManager.default
        var seen: [String: ModelInfo] = [:]

        for variant in ModelCatalog.all {
            let url = installedURL(for: variant.downloadSource)
            if isFullyDownloaded(at: url) {
                seen[variant.id] = modelInfo(for: variant, url: url, isInstalled: true)
            }
        }

        let catalogPaths: Set<String> = Set(ModelCatalog.all.map {
            installedURL(for: $0.downloadSource).standardizedFileURL.path
        })
        // FluidAudio's cache drops the "-coreml" suffix our catalog repo carries, leaving a de-suffixed twin dir for the same model; match it by name so the twin isn't listed as a stray orphan.
        let catalogDirNames: Set<String> = Set(ModelCatalog.all.map {
            installedURL(for: $0.downloadSource).lastPathComponent
        })

        for root in orphanScanRoots {
            guard fm.fileExists(atPath: root.path) else { continue }
            let entries = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
            for url in entries {
                guard !url.lastPathComponent.hasPrefix("."),
                      (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                else { continue }
                let standardPath = url.standardizedFileURL.path
                if catalogPaths.contains(standardPath) { continue }
                if catalogDirNames.contains(url.lastPathComponent + "-coreml") { continue }
                let id = url.lastPathComponent
                if seen[id] != nil { continue }
                guard containsModelWeights(at: url) else { continue }
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

        return seen.values.sorted { $0.name < $1.name }
    }

    /// Deletes a model directory regardless of whether it's in the curated catalog.
    /// For orphan directories (id not in the catalog), removes the on-disk folder by walking
    /// the known repo roots — useful for cleaning up stale paths left by older releases.
    public func deleteAny(idOrPath name: String) throws {
        if ModelCatalog.variant(id: name) != nil {
            try delete(variant: name)
            return
        }
        for root in orphanScanRoots {
            let candidate = root.appendingPathComponent(name, isDirectory: true)
            if FileManager.default.fileExists(atPath: candidate.path) {
                do {
                    try FileManager.default.removeItem(at: candidate)
                    return
                } catch {
                    throw ParolaError.ioError("Failed to delete \(name): \(error.localizedDescription)")
                }
            }
        }
        throw ParolaError.modelNotFound(name)
    }

    private func modelInfo(for variant: ModelVariant, url: URL?, isInstalled: Bool) -> ModelInfo {
        ModelInfo(
            name: variant.id,
            label: variant.displayName,
            approximateSizeBytes: Int(variant.sizeBytes),
            isMultilingual: variant.languageScope == nil,
            isInstalled: isInstalled,
            installedURL: url
        )
    }

    public func isInstalled(_ variant: String) -> Bool {
        if let entry = ModelCatalog.variant(id: variant), entry.engineID == .appleSpeech {
            return true
        }
        return isFullyDownloaded(at: installedURL(for: variant))
    }

    /// Downloads a model variant into our cache directory. If already present, returns immediately.
    /// - Parameter progress: 0.0–1.0 progress callback (best-effort).
    public func download(
        variant: String,
        progress: (@Sendable (Double) -> Void)? = nil,
        registry: EngineRegistry = .shared
    ) async throws -> URL {
        if isInstalled(variant) {
            progress?(1.0)
            return installedURL(for: variant)
        }
        guard let entry = ModelCatalog.variant(id: variant) else {
            let fallbackSource = ModelDownloadSource(
                huggingFaceRepo: "argmaxinc/whisperkit-coreml",
                subpath: variant
            )
            if let downloader = await registry.downloader(for: .whisperKit) {
                return try await downloadViaRegistry(
                    downloader, variant: variant, source: fallbackSource, progress: progress
                )
            }
            return try await downloadViaHuggingFace(source: fallbackSource, progress: progress)
        }
        if let downloader = await registry.downloader(for: entry.engineID) {
            return try await downloadViaRegistry(
                downloader, variant: variant, source: entry.downloadSource, progress: progress
            )
        }
        return try await downloadViaHuggingFace(source: entry.downloadSource, progress: progress)
    }

    /// Wraps an engine-supplied downloader in the same sidecar protocol the HuggingFace path
    /// uses, so an interrupted fetch is never mistaken for an installed model.
    private func downloadViaRegistry(
        _ downloader: EngineRegistry.Downloader,
        variant: String,
        source: ModelDownloadSource,
        progress: (@Sendable (Double) -> Void)?
    ) async throws -> URL {
        let destination = installedURL(for: source)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let sidecar = destination.appendingPathComponent(HuggingFaceDownloader.sidecarFilename)
        if !FileManager.default.fileExists(atPath: sidecar.path) {
            let placeholder = DownloadSidecar(repo: source.huggingFaceRepo, revision: "main", files: [:])
            try? placeholder.write(to: sidecar)
        }
        let result = try await downloader(variant, self, progress)
        // WhisperKit's HubApi returns success when cancelled between files; keep the sidecar then.
        try Task.checkCancellation()
        try? FileManager.default.removeItem(at: sidecar)
        return result
    }

    private func downloadViaHuggingFace(
        source: ModelDownloadSource,
        progress: (@Sendable (Double) -> Void)?
    ) async throws -> URL {
        let destination = installedURL(for: source)
        let alreadyExisted = FileManager.default.fileExists(atPath: destination.path)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        if !alreadyExisted {
            let placeholder = DownloadSidecar(repo: source.huggingFaceRepo, revision: "main", files: [:])
            try? placeholder.write(to: destination.appendingPathComponent(HuggingFaceDownloader.sidecarFilename))
        }
        do {
            try await HuggingFaceDownloader.snapshot(
                repo: source.huggingFaceRepo,
                subpath: source.subpath.isEmpty ? nil : source.subpath,
                destination: destination,
                progress: progress
            )
            progress?(1.0)
            return destination
        } catch is CancellationError {
            throw CancellationError()
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
