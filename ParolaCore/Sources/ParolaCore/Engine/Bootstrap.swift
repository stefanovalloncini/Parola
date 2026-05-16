import Foundation

public enum ParolaCoreBootstrap {
    /// Registers built-in engines into the shared `EngineRegistry`. Idempotent.
    /// Call once at app launch (and once at the start of CLI commands that transcribe).
    public static func registerBuiltInEngines(registry: EngineRegistry = .shared) async {
        await registry.register(
            engineID: WhisperKitTranscriber.engineID,
            capabilities: WhisperKitTranscriber.capabilities
        ) { store in
            WhisperKitTranscriber(modelStore: store)
        }
        await registry.register(
            engineID: ParakeetTranscriber.engineID,
            capabilities: ParakeetTranscriber.capabilities
        ) { store in
            ParakeetTranscriber(modelStore: store)
        }
    }
}
