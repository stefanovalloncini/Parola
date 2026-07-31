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
    private let managedConfiguration: ManagedConfiguration
    private let downloadGate = DownloadGate()

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

    /// Directories the app fills for a background service rather than for a catalog model. They live
    /// under the same scan roots but are in use, so the orphan list must not offer them for deletion.
    private var serviceOwnedDirectories: [URL] {
        [IncrementalSpeakerLabeler.modelsDirectory(store: self)]
    }

    public init(
        modelsDirectory: URL? = nil,
        defaults: UserDefaults = .standard,
        sharedOverrideFile: URL = ModelStore.sharedOverrideFileURL,
        managedConfiguration: ManagedConfiguration = .shared
    ) {
        self.managedConfiguration = managedConfiguration
        if let modelsDirectory {
            self.modelsDirectory = modelsDirectory
        } else if let raw = defaults.string(forKey: Self.storageOverrideKey),
                  !raw.trimmingCharacters(in: .whitespaces).isEmpty {
            self.modelsDirectory = URL(fileURLWithPath: (raw as NSString).expandingTildeInPath, isDirectory: true)
        } else if let shared = Self.sharedOverridePath(at: sharedOverrideFile) {
            self.modelsDirectory = URL(fileURLWithPath: (shared as NSString).expandingTildeInPath, isDirectory: true)
        } else {
            self.modelsDirectory = Self.defaultDirectory
        }
        try? FileManager.default.createDirectory(at: self.modelsDirectory, withIntermediateDirectories: true)
    }

    /// Cross-process home of the storage override. The app writes it whenever the setting
    /// changes, so the `parola` CLI — a separate defaults domain — resolves the same folder.
    public static var sharedOverrideFileURL: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
            .appendingPathComponent("Parola", isDirectory: true)
            .appendingPathComponent("models-path.txt", isDirectory: false)
    }

    /// Writes the storage override to the shared file, or removes the file for nil/blank.
    public static func writeSharedOverride(_ path: String?, to file: URL = sharedOverrideFileURL) {
        let trimmed = path?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else {
            try? FileManager.default.removeItem(at: file)
            return
        }
        try? FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? trimmed.write(to: file, atomically: true, encoding: .utf8)
    }

    private static func sharedOverridePath(at file: URL) -> String? {
        guard let raw = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
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
        modelsDirectory
            .appendingPathComponent("models", isDirectory: true)
            .appendingPathComponent(source.installDirectory, isDirectory: true)
    }

    /// Returns the curated catalog merged with what's actually on disk.
    /// Filters by the managed-config engine allowlist if one is set.
    public func catalog() -> [ModelInfo] {
        managedConfiguration.filterAllowed(ModelCatalog.all).map { variant in
            if variant.engineID == .appleSpeech {
                return modelInfo(for: variant, url: nil, isInstalled: true)
            }
            let url = installedURL(for: variant.downloadSource)
            let installed = isFullyDownloaded(at: url)
            return modelInfo(for: variant, url: installed ? url : nil, isInstalled: installed)
        }
    }

    /// A model directory counts as installed only when no download sidecar remains and the
    /// directory actually holds weights. HuggingFaceDownloader leaves that sidecar behind while a
    /// fetch is incomplete and removes it on success; the weights check catches the directories an
    /// engine downloader creates but fills somewhere else.
    private func isFullyDownloaded(at url: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        let sidecar = url.appendingPathComponent(HuggingFaceDownloader.sidecarFilename)
        guard !FileManager.default.fileExists(atPath: sidecar.path) else { return false }
        return containsModelWeights(at: url) && compiledBundlesAreComplete(at: url)
    }

    /// A compiled CoreML bundle is usable only once its metadata and weights have both landed. An
    /// interrupted fetch leaves the `.mlmodelc` behind with an empty `weights` directory, which
    /// otherwise reads as a finished install and fails at load time with a CoreML parse error.
    private func compiledBundlesAreComplete(at url: URL) -> Bool {
        let fm = FileManager.default
        let entries = (try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []
        for bundle in entries where bundle.pathExtension == "mlmodelc" {
            // A compiled bundle is a directory; anything else with that extension isn't one.
            guard (try? bundle.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
            guard fm.fileExists(atPath: bundle.appendingPathComponent("coremldata.bin").path) else {
                return false
            }
            let weights = bundle.appendingPathComponent("weights", isDirectory: true)
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: weights.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                continue
            }
            if ((try? fm.contentsOfDirectory(atPath: weights.path)) ?? []).isEmpty { return false }
        }
        return true
    }

    /// True when a directory holds something other than tokenizer/config metadata —
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

        for variant in managedConfiguration.filterAllowed(ModelCatalog.all) {
            let url = installedURL(for: variant.downloadSource)
            if isFullyDownloaded(at: url) {
                seen[variant.id] = modelInfo(for: variant, url: url, isInstalled: true)
            }
        }

        let reservedPaths: Set<String> = Set(
            (ModelCatalog.all.map { installedURL(for: $0.downloadSource) } + serviceOwnedDirectories)
                .map(\.standardizedFileURL.path)
        )

        for root in orphanScanRoots {
            guard fm.fileExists(atPath: root.path) else { continue }
            let entries = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
            for url in entries {
                guard !url.lastPathComponent.hasPrefix("."),
                      (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                else { continue }
                if reservedPaths.contains(url.standardizedFileURL.path) { continue }
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
        guard !name.contains("/"), name != ".", name != ".." else {
            throw ParolaError.modelNotFound(name)
        }
        let reservedPaths = Set(serviceOwnedDirectories.map(\.standardizedFileURL.path))
        for root in orphanScanRoots {
            let candidate = root.appendingPathComponent(name, isDirectory: true)
            guard !reservedPaths.contains(candidate.standardizedFileURL.path) else { continue }
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
    /// Concurrent calls for the same variant are serialized; the loser returns the winner's result.
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
        try checkDownloadPolicy(variant: variant)
        if ModelCatalog.variant(id: variant) == nil,
           let suggestion = ModelCatalog.closestMatch(for: variant) {
            throw ParolaError.unknownModel(variant, suggestion: suggestion.id)
        }
        return try await downloadGate.serialized(variant) {
            try await self.downloadNow(variant: variant, progress: progress, registry: registry)
        }
    }

    private func checkDownloadPolicy(variant: String) throws {
        if managedConfiguration.disableModelDownloads {
            throw ParolaError.policyRestricted("Model downloads are disabled by a managed policy.")
        }
        if let entry = ModelCatalog.variant(id: variant),
           let allowed = managedConfiguration.allowedEngines,
           !allowed.contains(entry.engineID) {
            throw ParolaError.policyRestricted(
                "The \(entry.engineID.displayName) engine is disabled by a managed policy."
            )
        }
    }

    private func downloadNow(
        variant: String,
        progress: (@Sendable (Double) -> Void)?,
        registry: EngineRegistry
    ) async throws -> URL {
        if isInstalled(variant) {
            progress?(1.0)
            return installedURL(for: variant)
        }
        let source = ModelCatalog.variant(id: variant)?.downloadSource ?? ModelDownloadSource(
            huggingFaceRepo: "argmaxinc/whisperkit-coreml",
            subpath: variant
        )
        let engineID = ModelCatalog.variant(id: variant)?.engineID ?? .whisperKit
        var downloader = await registry.downloader(for: engineID)
        if downloader == nil {
            await ParolaCoreBootstrap.registerBuiltInEngines(registry: registry)
            downloader = await registry.downloader(for: engineID)
        }
        if let downloader {
            return try await downloadViaRegistry(
                downloader, variant: variant, source: source, progress: progress
            )
        }
        // The generic snapshot only reproduces WhisperKit's repo-per-subpath layout. Taking it for
        // another engine downloads a directory that engine will never read, so refuse instead.
        guard engineID == .whisperKit else {
            throw ParolaError.engineNotRegistered(engineID.rawValue)
        }
        return try await downloadViaHuggingFace(source: source, progress: progress)
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
        // Engine downloaders report their own coarse fractions and rarely end at 1.0.
        progress?(1.0)
        return result
    }

    private func downloadViaHuggingFace(
        source: ModelDownloadSource,
        progress: (@Sendable (Double) -> Void)?
    ) async throws -> URL {
        let destination = installedURL(for: source)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        // A directory left over from an earlier attempt gets a sidecar too: without one, an
        // interrupted retry would leave a half-filled directory reporting as installed.
        let sidecar = destination.appendingPathComponent(HuggingFaceDownloader.sidecarFilename)
        if !FileManager.default.fileExists(atPath: sidecar.path) {
            let placeholder = DownloadSidecar(repo: source.huggingFaceRepo, revision: "main", files: [:])
            try? placeholder.write(to: sidecar)
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
        } catch {
            if isCancellation(error) { throw CancellationError() }
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

/// Serializes downloads per model id so two callers (say, the Settings download button and a
/// transcribe-triggered auto-download) never write the same model directory at once.
actor DownloadGate {
    private var busy: Set<String> = []
    private var waiters: [String: [CheckedContinuation<Void, Never>]] = [:]

    func serialized<T: Sendable>(
        _ key: String,
        _ body: @Sendable () async throws -> T
    ) async throws -> T {
        while busy.contains(key) {
            try Task.checkCancellation()
            // On cancel, wake every waiter for this key: the cancelled one re-loops into the
            // check above and throws; the rest re-queue.
            await withTaskCancellationHandler {
                await withCheckedContinuation { waiters[key, default: []].append($0) }
            } onCancel: {
                Task { await self.wakeWaiters(for: key) }
            }
        }
        busy.insert(key)
        defer {
            busy.remove(key)
            wakeWaiters(for: key)
        }
        return try await body()
    }

    private func wakeWaiters(for key: String) {
        let queue = waiters.removeValue(forKey: key) ?? []
        for waiter in queue { waiter.resume() }
    }
}
