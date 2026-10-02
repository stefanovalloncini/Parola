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
                summary: "Stops and saves a take in progress, as the quit prompt's Stop and Save does, cancels the rest of the in-flight work, removes the bridge discovery file, and terminates the app.",
                kind: .async,
                handler: { _, ctx in
                    let model = ctx.model
                    await model.stopAndSaveTakeForQuit()
                    model.cancelAllTasks()
                    ctx.server.stop()
                    let library = model.library
                    let terminate = ctx.server.terminateApp
                    Task { @MainActor in
                        await library.flush()
                        try? await Task.sleep(for: .milliseconds(50))
                        // The app delegate turns a terminate down while a quit is pending, and this one has done its waiting.
                        model.quitPending = false
                        terminate()
                    }
                    return .object(["terminating": .bool(true)])
                }
            ),

            AutomationCommand(
                name: "resetTestState",
                area: .test,
                summary: "Wipes in-memory and on-disk state, once a take still saving lands (5 s at most). Test-mode only.",
                kind: .mutating,
                handler: { _, ctx in
                    guard ctx.model.mode == .test else {
                        throw AutomationError.precondition("resetTestState is only available in --test-mode")
                    }
                    let model = ctx.model
                    model.noticeUnderMacAudio = nil
                    model.cancelAllTasks()
                    await ctx.server.releaseHeldStreamingStart()
                    await model.settleTakeWork(within: .seconds(5))
                    model.dismissTakeSaved()
                    model.forgetTakeSession()
                    model.abortDictation()
                    await model.unloadTranscriptionSession()
                    model.batchJobs = []
                    model.clearLoadedEntry()
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
                    await MockLanguageModelStore.shared.withLease { await MockLanguageModelStore.shared.clear() }
                    await MockAudioSourceRegistry.shared.clear()
                    CapturedInsertionStore.shared.clear()
                    model.linkFetcher = YtDlpLinkFetcher(features: model.features)
                    return .object(["reset": .bool(true)])
                }
            ),
        ]
    }
}
