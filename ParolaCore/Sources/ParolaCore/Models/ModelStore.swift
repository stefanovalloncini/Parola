import Foundation
import os

/// The catalog and installed-model views of one filesystem scan.
public struct ModelScan: Sendable {
    public let catalog: [ModelInfo]
    public let installed: [ModelInfo]
}

/// The slice of a Whisper `config.json` that identifies which checkpoint a folder holds.
private struct WhisperCheckpointConfig: Decodable {
    let decoderLayers: Int?

    enum CodingKeys: String, CodingKey {
        case decoderLayers = "decoder_layers"
    }
}

/// Weights an earlier release installed for a variant that has since moved to another folder.
/// Nothing loads them; `ModelStore.deleteLeftovers(variant:)` clears them.
public struct SupersededInstall: Sendable, Hashable {
    public let variantID: String
    public let displayName: String
    public let url: URL
}

/// Manages the on-disk cache of transcription models.
///
/// Both the macOS app and the CLI use the same cache directory so a model
/// downloaded by either is visible to the other.
///
/// Configuration is immutable after init and the scan cache sits behind a lock, so the type is
/// `Sendable` without actor isolation.
public final class ModelStore: Sendable {
    /// Set before the first `shared` access to point the singleton at another folder; the
    /// app writes it from `--models=` so a sandboxed launch never reads the real model store.
    public nonisolated(unsafe) static var sharedDirectoryOverride: URL?

    public static let shared = ModelStore(modelsDirectory: sharedDirectoryOverride)

    private let modelsDirectory: URL
    private let managedConfiguration: ManagedConfiguration
    private let downloadGate = DownloadGate()
    private let cachedScanState = OSAllocatedUnfairLock<CachedScan?>(initialState: nil)

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
        do {
            try FileManager.default.createDirectory(
                at: self.modelsDirectory,
                withIntermediateDirectories: true
            )
        } catch {
            ParolaLog.error(.models, "could not create the models directory", [.error: .error(error)])
        }
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

    /// Directories an earlier release installed a variant into, whether or not they still exist.
    private func supersededURLs(for source: ModelDownloadSource) -> [URL] {
        source.supersededInstallDirectories.map {
            modelsDirectory
                .appendingPathComponent("models", isDirectory: true)
                .appendingPathComponent($0, isDirectory: true)
        }
    }

    /// Leftover weights from a variant that has since moved to another folder, so a caller can
    /// show what an upgrade orphaned. Only directories that still hold weights are listed.
    public func supersededInstalls() -> [SupersededInstall] {
        ModelCatalog.all.flatMap { variant in
            supersededURLs(for: variant.downloadSource)
                .filter { url in
                    guard let entries = try? FileManager.default.contentsOfDirectory(
                        at: url, includingPropertiesForKeys: [.isDirectoryKey]
                    ) else { return false }
                    return containsModelWeights(in: entries)
                }
                .map {
                    SupersededInstall(variantID: variant.id, displayName: variant.displayName, url: $0)
                }
        }
    }

    /// Returns the curated catalog merged with what's actually on disk.
    /// Filters by the managed-config engine allowlist if one is set.
    public func catalog() -> [ModelInfo] {
        scan().catalog
    }

    /// Returns models present on disk, even if not in the curated catalog. Includes
    /// orphan directories left by older app versions or by engine wrappers that
    /// used a different naming convention.
    public func installedModels() throws -> [ModelInfo] {
        scan().installed
    }

    /// One scan root's immediate subdirectories, plus the entry names and modification dates that
    /// tell a repeat scan whether anything under it moved.
    private struct RootListing: Sendable {
        let root: URL
        let directories: [URL]
        let stamp: [String: Date]
    }

    private struct ScanRoots: Sendable {
        let listings: [RootListing]
        let allowedVariants: [ModelVariant]
    }

    private struct CachedScan: Sendable {
        let stamps: [[String: Date]]
        let allowedVariants: [ModelVariant]
        let scan: ModelScan

        func matches(_ roots: ScanRoots) -> Bool {
            allowedVariants == roots.allowedVariants && stamps == roots.listings.map(\.stamp)
        }
    }

    /// Reads the model directories once and derives both the catalog and installed-model views.
    /// A repeat call whose scan roots are unchanged replays the previous result.
    ///
    /// The stamp covers each root's entries and their modification dates, so an install, a delete
    /// or a finished download is picked up. A mutation buried deeper — weights appearing inside an
    /// existing `.mlmodelc` — is not; that model still reports installed until something at the top
    /// of its directory changes, and a wrong claim surfaces when the engine fails to load it.
    public func scan() -> ModelScan {
        let roots = scanRoots()
        if let cached = cachedScanState.withLock({ $0 }), cached.matches(roots) {
            return cached.scan
        }
        let scan = performScan(roots)
        cachedScanState.withLock {
            $0 = CachedScan(
                stamps: roots.listings.map(\.stamp),
                allowedVariants: roots.allowedVariants,
                scan: scan
            )
        }
        return scan
    }

    /// The last scan, or nil once the scan roots stop looking the way they did when it ran.
    /// Revalidating re-lists each root, so this is real I/O — a fraction of a millisecond on a local
    /// disk, unbounded on a network volume — but it skips the per-model walk a full scan does.
    public func cachedScan() -> ModelScan? {
        guard let cached = cachedScanState.withLock({ $0 }) else { return nil }
        return cached.matches(scanRoots()) ? cached.scan : nil
    }

    private func scanRoots() -> ScanRoots {
        var seenPaths: Set<String> = []
        var roots: [URL] = []
        let candidates = orphanScanRoots + ModelCatalog.all.map {
            installedURL(for: $0.downloadSource).deletingLastPathComponent()
        }
        for candidate in candidates where seenPaths.insert(candidate.standardizedFileURL.path).inserted {
            roots.append(candidate)
        }

        let keys: [URLResourceKey] = [.contentModificationDateKey, .isDirectoryKey]
        let listings = roots.map { root -> RootListing in
            let entries = (try? FileManager.default.contentsOfDirectory(
                at: root, includingPropertiesForKeys: keys
            )) ?? []
            var stamp: [String: Date] = [:]
            var directories: [URL] = []
            for entry in entries {
                let values = try? entry.resourceValues(forKeys: Set(keys))
                stamp[entry.lastPathComponent] = values?.contentModificationDate ?? .distantPast
                if values?.isDirectory == true, !entry.lastPathComponent.hasPrefix(".") {
                    directories.append(entry)
                }
            }
            return RootListing(root: root, directories: directories, stamp: stamp)
        }
        return ScanRoots(
            listings: listings,
            allowedVariants: managedConfiguration.filterAllowed(ModelCatalog.all)
        )
    }

    private func performScan(_ roots: ScanRoots) -> ModelScan {
        var catalogEntries: [ModelInfo] = []
        var installedByID: [String: ModelInfo] = [:]

        for variant in roots.allowedVariants {
            let url = installedURL(for: variant.downloadSource)
            let onDisk = isFullyDownloaded(at: url, expecting: variant)
            // Apple Speech ships with macOS: the catalog always calls it installed, and it owns no
            // directory, so the installed-models view only lists it if one somehow exists.
            let builtIn = variant.engineID == .appleSpeech
            catalogEntries.append(modelInfo(
                for: variant,
                url: builtIn ? nil : (onDisk ? url : nil),
                isInstalled: builtIn || onDisk
            ))
            if onDisk {
                installedByID[variant.id] = modelInfo(for: variant, url: url, isInstalled: true)
            }
        }

        // Superseded directories are reserved too: listing one as an orphan would show a second
        // row under the variant's own id, claiming installed for a model nothing can load.
        let catalogDirectories = ModelCatalog.all.flatMap {
            [installedURL(for: $0.downloadSource)] + supersededURLs(for: $0.downloadSource)
        }
        let reservedPaths: Set<String> = Set(
            (catalogDirectories + serviceOwnedDirectories).map(\.standardizedFileURL.path)
        )
        let orphanRootPaths = Set(orphanScanRoots.map(\.standardizedFileURL.path))

        for listing in roots.listings where orphanRootPaths.contains(listing.root.standardizedFileURL.path) {
            for url in listing.directories {
                if reservedPaths.contains(url.standardizedFileURL.path) { continue }
                let id = url.lastPathComponent
                if installedByID[id] != nil { continue }
                guard let entries = try? FileManager.default.contentsOfDirectory(
                    at: url, includingPropertiesForKeys: [.isDirectoryKey]
                ), containsModelWeights(in: entries) else { continue }
                installedByID[id] = ModelInfo(
                    name: id,
                    label: id,
                    approximateSizeBytes: nil,
                    isMultilingual: !id.hasSuffix(".en"),
                    isInstalled: true,
                    installedURL: url
                )
            }
        }

        return ModelScan(
            catalog: catalogEntries,
            installed: installedByID.values.sorted { $0.name < $1.name }
        )
    }

    /// A model directory counts as installed only when no download sidecar remains and the
    /// directory actually holds weights. HuggingFaceDownloader leaves that sidecar behind while a
    /// fetch is incomplete and removes it on success; the weights check catches the directories an
    /// engine downloader creates but fills somewhere else.
    private func isFullyDownloaded(at url: URL, expecting variant: ModelVariant? = nil) -> Bool {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: [.isDirectoryKey]
        ) else { return false }
        guard !entries.contains(where: { $0.lastPathComponent == HuggingFaceDownloader.sidecarFilename })
        else { return false }
        return containsModelWeights(in: entries)
            && compiledBundlesAreComplete(in: entries)
            && checkpointMatches(variant, at: url)
    }

    /// Guards against the wrong checkpoint sitting under the right folder name — weights left by an
    /// older catalog, or a repo folder whose contents don't match what its name advertises. A config
    /// we can't read or that omits the depth passes: a re-download is worse than a missed check.
    private func checkpointMatches(_ variant: ModelVariant?, at url: URL) -> Bool {
        guard let expected = variant?.expectedDecoderLayers else { return true }
        guard let data = try? Data(contentsOf: url.appendingPathComponent("config.json")),
              let config = try? JSONDecoder().decode(WhisperCheckpointConfig.self, from: data),
              let layers = config.decoderLayers
        else { return true }
        return layers == expected
    }

    /// A compiled CoreML bundle is usable only once its metadata and weights have both landed. An
    /// interrupted fetch leaves the `.mlmodelc` behind with an empty `weights` directory, which
    /// otherwise reads as a finished install and fails at load time with a CoreML parse error.
    private func compiledBundlesAreComplete(in entries: [URL]) -> Bool {
        let fm = FileManager.default
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
    private func containsModelWeights(in entries: [URL]) -> Bool {
        entries.contains { entry in
            let name = entry.lastPathComponent
            guard !name.hasPrefix(".") else { return false }
            return !Self.modelMetadataFilenames.contains(name.lowercased())
        }
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
                    ParolaLog.error(
                        .models,
                        "delete failed for \(ModelToken(name))",
                        [.error: .error(error)]
                    )
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
        let entry = ModelCatalog.variant(id: variant)
        if entry?.engineID == .appleSpeech { return true }
        return isFullyDownloaded(at: installedURL(for: variant), expecting: entry)
    }

    /// Downloads a model variant into our cache directory. If already present, returns immediately.
    /// Concurrent calls for the same variant are serialized; the loser returns the winner's result.
    /// - Parameter progress: 0.0–1.0 progress callback (best-effort).
    public func download(
        variant: String,
        progress: (@Sendable (Double) -> Void)? = nil,
        registry: EngineRegistry = .shared,
        urlSession: URLSession = .shared
    ) async throws -> URL {
        if isInstalled(variant) {
            progress?(1.0)
            return installedURL(for: variant)
        }
        try checkDownloadPolicy(variant: variant)
        if ModelCatalog.variant(id: variant) == nil,
           let suggestion = ModelCatalog.closestMatch(for: variant) {
            ParolaLog.error(.models, "unknown model \(ModelToken(variant))")
            throw ParolaError.unknownModel(variant, suggestion: suggestion.id)
        }
        return try await downloadGate.serialized(variant) {
            ParolaLog.info(
                .models,
                "download starting for \(ModelToken(variant))",
                Self.catalogSizeFields(variant)
            )
            return try await self.downloadNow(
                variant: variant,
                progress: progress,
                registry: registry,
                urlSession: urlSession
            )
        }
    }

    private static func catalogSizeFields(_ variant: String) -> [LogField: LogValue] {
        guard let size = ModelCatalog.variant(id: variant)?.sizeBytes else { return [:] }
        return [.bytes: .bytes(size)]
    }

    private func checkDownloadPolicy(variant: String) throws {
        if managedConfiguration.disableModelDownloads {
            ParolaLog.notice(.models, "download blocked by policy")
            throw ParolaError.policyRestricted("Model downloads are disabled by a managed policy.")
        }
        if let entry = ModelCatalog.variant(id: variant),
           let allowed = managedConfiguration.allowedEngines,
           !allowed.contains(entry.engineID) {
            ParolaLog.notice(.models, "download blocked by policy for \(entry.engineID)")
            throw ParolaError.policyRestricted(
                "The \(entry.engineID.displayName) engine is disabled by a managed policy."
            )
        }
    }

    private func downloadNow(
        variant: String,
        progress: (@Sendable (Double) -> Void)?,
        registry: EngineRegistry,
        urlSession: URLSession
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
        // Only bootstrap a registry nobody has populated: register(engineID:) replaces the whole
        // entry, so seeding built-ins over a caller's own engines would swap out their factory too.
        if downloader == nil, await registry.registeredEngines().isEmpty {
            await ParolaCoreBootstrap.registerBuiltInEngines(registry: registry)
            downloader = await registry.downloader(for: engineID)
        }
        if let downloader {
            return try await downloadViaRegistry(
                downloader,
                name: source.downloadName(defaultingTo: variant),
                source: source,
                progress: progress
            )
        }
        // The generic snapshot only reproduces WhisperKit's repo-per-subpath layout. Taking it for
        // another engine downloads a directory that engine will never read, so refuse instead.
        guard engineID == .whisperKit else {
            ParolaLog.error(.models, "no downloader registered for \(engineID)")
            throw ParolaError.engineNotRegistered(engineID.rawValue)
        }
        return try await downloadViaHuggingFace(
            variant: variant,
            source: source,
            progress: progress,
            urlSession: urlSession
        )
    }

    /// Wraps an engine-supplied downloader in the same sidecar protocol the HuggingFace path
    /// uses, so an interrupted fetch is never mistaken for an installed model.
    private func downloadViaRegistry(
        _ downloader: EngineRegistry.Downloader,
        name: String,
        source: ModelDownloadSource,
        progress: (@Sendable (Double) -> Void)?
    ) async throws -> URL {
        let startedAt = ContinuousClock.now
        let destination = installedURL(for: source)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let sidecar = destination.appendingPathComponent(HuggingFaceDownloader.sidecarFilename)
        if !FileManager.default.fileExists(atPath: sidecar.path) {
            let placeholder = DownloadSidecar(repo: source.huggingFaceRepo, revision: "main", files: [:])
            try? placeholder.write(to: sidecar)
        }
        let result = try await downloader(name, self, progress)
        // WhisperKit's HubApi returns success when cancelled between files; keep the sidecar then.
        try Task.checkCancellation()
        try? FileManager.default.removeItem(at: sidecar)
        // Engine downloaders report their own coarse fractions and rarely end at 1.0.
        progress?(1.0)
        ParolaLog.info(
            .models,
            "download finished for \(ModelToken(name))",
            self.installedSizeFields(at: result, startedAt: startedAt)
        )
        return result
    }

    /// Walks the finished install, so it only runs when the fields autoclosure is evaluated.
    private func installedSizeFields(
        at url: URL,
        startedAt: ContinuousClock.Instant
    ) -> [LogField: LogValue] {
        var fields: [LogField: LogValue] = [.elapsed: .duration(startedAt.duration(to: .now))]
        if let bytes = sizeOnDisk(at: url) { fields[.bytes] = .bytes(Int64(bytes)) }
        return fields
    }

    private func downloadViaHuggingFace(
        variant: String,
        source: ModelDownloadSource,
        progress: (@Sendable (Double) -> Void)?,
        urlSession: URLSession
    ) async throws -> URL {
        let startedAt = ContinuousClock.now
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
                urlSession: urlSession,
                progress: progress
            )
            progress?(1.0)
            return destination
        } catch {
            if isCancellation(error) { throw CancellationError() }
            ParolaLog.error(
                .models,
                "download failed",
                [
                    .model: .safe(ModelToken(variant)),
                    .elapsed: .duration(startedAt.duration(to: .now)),
                    .error: .error(error),
                ]
            )
            throw ParolaError.modelDownloadFailed(source.huggingFaceRepo, underlying: String(describing: error))
        }
    }

    /// Removes the directory a variant is installed in now. Copies an earlier release left
    /// elsewhere survive — `deleteLeftovers(variant:)` clears those.
    public func delete(variant: String) throws {
        try remove([installedURL(for: variant)], describedBy: variant)
    }

    /// Removes the directories an earlier release installed a variant into, leaving the current
    /// install in place.
    public func deleteLeftovers(variant: String) throws {
        let superseded = ModelCatalog.variant(id: variant).map { supersededURLs(for: $0.downloadSource) } ?? []
        try remove(superseded, describedBy: variant)
    }

    private func remove(_ urls: [URL], describedBy variant: String) throws {
        let targets = urls.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !targets.isEmpty else {
            throw ParolaError.modelNotFound(variant)
        }
        for url in targets {
            do {
                try FileManager.default.removeItem(at: url)
            } catch {
                ParolaLog.error(
                    .models,
                    "delete failed for \(ModelToken(variant))",
                    [.error: .error(error)]
                )
                throw ParolaError.ioError("Failed to delete \(variant): \(error.localizedDescription)")
            }
        }
    }

    public func sizeOnDisk(_ variant: String) -> Int? {
        sizeOnDisk(at: installedURL(for: variant))
    }

    /// Bytes under a model directory. Walks the whole tree, so callers keep it off the main thread.
    public func sizeOnDisk(at url: URL) -> Int? {
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
