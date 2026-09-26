import Foundation

public enum ParolaCoreBootstrap {
    /// Each built-in engine's declared capabilities; the catalog's synchronous lookup reads them too.
    static let builtInCapabilities: [EngineID: EngineCapabilities] = [
        WhisperKitTranscriber.engineID: WhisperKitTranscriber.capabilities,
        ParakeetTranscriber.engineID: ParakeetTranscriber.capabilities,
        AppleSpeechTranscriber.engineID: AppleSpeechTranscriber.capabilities,
    ]

    /// Registers built-in engines into the shared `EngineRegistry`. Idempotent.
    /// Call once at app launch (and once at the start of CLI commands that transcribe).
    public static func registerBuiltInEngines(registry: EngineRegistry = .shared) async {
        await registry.register(
            engineID: WhisperKitTranscriber.engineID,
            capabilities: WhisperKitTranscriber.capabilities,
            factory: { store in WhisperKitTranscriber(modelStore: store) },
            downloader: { variant, store, progress in
                try await WhisperKitTranscriber.download(
                    variant: variant,
                    downloadBase: store.directory,
                    progress: progress
                )
            }
        )
        await registry.register(
            engineID: ParakeetTranscriber.engineID,
            capabilities: ParakeetTranscriber.capabilities,
            factory: { store in ParakeetTranscriber(modelStore: store) },
            downloader: { variant, store, progress in
                try await ParakeetTranscriber.download(
                    model: variant,
                    to: store.installedURL(for: variant),
                    progress: progress
                )
            }
        )
        if #available(macOS 26.0, iOS 26.0, *) {
            await registry.register(
                engineID: AppleSpeechTranscriber.engineID,
                capabilities: AppleSpeechTranscriber.capabilities,
                factory: { store in AppleSpeechTranscriber(modelStore: store) },
                downloader: { variant, store, progress in
                    progress?(1.0)
                    return store.installedURL(for: variant)
                }
            )
        }
    }
}
