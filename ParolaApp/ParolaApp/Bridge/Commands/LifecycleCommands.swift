import Foundation
import AppKit
import ParolaCore
import ParolaDictation

extension ParolaAutomationServer {
    func lifecycleCommands() -> [AutomationCommand] {
        [
            AutomationCommand(
                name: "quit",
                area: .lifecycle,
                summary: "Cancels in-flight work, removes the bridge discovery file, and terminates the app.",
                kind: .async,
                handler: { _, ctx in
                    ctx.model.cancelAllTasks()
                    ctx.server.stop()
                    let library = ctx.model.library
                    Task { @MainActor in
                        await library.flush()
                        try? await Task.sleep(for: .milliseconds(50))
                        NSApp.terminate(nil)
                    }
                    return .object(["terminating": .bool(true)])
                }
            ),

            AutomationCommand(
                name: "resetTestState",
                area: .test,
                summary: "Wipes in-memory and on-disk state. Test-mode only.",
                kind: .mutating,
                handler: { _, ctx in
                    guard ctx.model.mode == .test else {
                        throw AutomationError.precondition("resetTestState is only available in --test-mode")
                    }
                    let model = ctx.model
                    model.cancelAllTasks()
                    await model.unloadTranscriptionSession()
                    model.batchJobs = []
                    model.transcript = nil
                    model.phase = .idle
                    model.libraryEntries = []
                    let libraryURL = model.library.libraryURL
                    try? FileManager.default.removeItem(at: libraryURL)
                    await model.library.dropCaches()
                    for key in model.defaults.dictionaryRepresentation().keys {
                        model.defaults.removeObject(forKey: key)
                    }
                    model.reloadSettings()
                    model.refreshLibrary()
                    await MockTranscriberRegistry.shared.clear()
                    MockStreamingTranscriberRegistry.shared.clear()
                    await MockLanguageModelStore.shared.clear()
                    await MockAudioSourceRegistry.shared.clear()
                    CapturedInsertionStore.shared.clear()
                    MockMediaFetcherRegistry.shared.clear()
                    return .object(["reset": .bool(true)])
                }
            ),
        ]
    }
}
