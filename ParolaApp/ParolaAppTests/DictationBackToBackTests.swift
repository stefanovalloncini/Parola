import CoreGraphics
import Foundation
import AppKit
import os
import Testing
@testable import Parola
import ParolaCore
import ParolaDictation
import ParolaTestSupport

// @unchecked: every field is touched only under `lock`.
private final class SpySession: StreamingTranscriber, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: AsyncStream<StreamingEvent>.Continuation?
    private(set) var calls: [String] = []
    let text: String
    let stopGate: AsyncStream<Void>

    init(text: String, stopGate: AsyncStream<Void>) {
        self.text = text
        self.stopGate = stopGate
    }

    var log: [String] { lock.withLock { calls } }

    func start(
        options: TranscriptionOptions,
        speakerLabeler: (any StreamingSpeakerLabeler)?,
        downloadProgress: (@Sendable (Double) -> Void)?
    ) async throws -> AsyncStream<StreamingEvent> {
        let (stream, continuation) = AsyncStream.makeStream(of: StreamingEvent.self)
        lock.withLock { self.continuation = continuation; calls.append("start") }
        return stream
    }

    func stopCapturing() async { lock.withLock { calls.append("stopCapturing") } }

    func stop() async {
        lock.withLock { calls.append("stop") }
        for await _ in stopGate {}
        let events = lock.withLock { continuation }
        events?.yield(.confirmed(TranscriptSegment(id: 0, start: 0, end: 1, text: text)))
        events?.finish()
    }

    func cancel() async {
        lock.withLock { calls.append("cancel") }
        lock.withLock { continuation }?.finish()
    }

    func currentModel() async -> String? { nil }
}

@MainActor
@Suite("Dictation back-to-back capture")
struct DictationBackToBackCaptureTests {
    @Test("the hotkey modifiers never reach a paste or a typed insertion")
    func eventsCarryOnlyTheirOwnFlags() {
        let paste = ClipboardPasteInserter.cmdVEvents()
        #expect(paste.down?.flags == .maskCommand)
        #expect(paste.up?.flags == .maskCommand)

        let typed = KeystrokeTextInserter.events(for: Array("w".utf16))
        #expect(typed.down?.flags.isEmpty == true)
        #expect(typed.up?.flags.isEmpty == true)
    }

    @Test("a take's mic is released at the stop and its tail decodes while the next take records", .timeLimit(.minutes(1)))
    func nextTakeStartsDuringTheTailDecode() async throws {
        let (gate, open) = AsyncStream<Void>.makeStream()
        let made = OSAllocatedUnfairLock<[SpySession]>(initialState: [])
        let texts = OSAllocatedUnfairLock<[String]>(initialState: ["one", "two"])
        let recorder = MicDictationRecorder(
            model: "openai_whisper-large-v3_turbo",
            language: nil,
            streamingEnabled: true,
            makeStreamingSession: {
                let text = texts.withLock { $0.removeFirst() }
                let session = SpySession(text: text, stopGate: gate)
                made.withLock { $0.append(session) }
                return session
            },
            warmFallbackModel: { _ in }
        )

        try await recorder.start()
        let first = try await recorder.stopCapture()
        #expect(made.withLock { $0[0].log } == ["start", "stopCapturing"])

        try await recorder.start()
        #expect(made.withLock { $0.count } == 2)
        let finalizing = Task { try await first.finalize() }
        await waitUntil { made.withLock { $0[0].log.contains("stop") } }
        #expect(made.withLock { $0[1].log } == ["start"], "the next take captures while the first still decodes")

        open.finish()
        #expect(try await finalizing.value == "one")
        #expect(try await recorder.stopAndTranscribe() == "two")
    }

    @Test("the tail words reach the partials while the take is being transcribed", .timeLimit(.minutes(1)))
    func tailWordsReachThePartials() async throws {
        let (gate, open) = AsyncStream<Void>.makeStream()
        let recorder = MicDictationRecorder(
            model: "openai_whisper-large-v3_turbo",
            language: nil,
            streamingEnabled: true,
            makeStreamingSession: { SpySession(text: "tail words", stopGate: gate) },
            warmFallbackModel: { _ in }
        )
        try await recorder.start()
        let asRecorder: any DictationRecorder = recorder
        let stream = await asRecorder.partials()
        let firstPartial = Task { () -> String? in
            for await text in stream { return text }
            return nil
        }
        let take = try await recorder.stopCapture()

        open.finish()
        let text = try await take.finalize()

        let heard = await AsyncTimeout.run(.seconds(5)) { await firstPartial.value } ?? nil
        #expect(heard == "tail words", "heard \(String(describing: heard))")
        #expect(text == "tail words")
    }

    @Test("a start while another take is capturing fails instead of doing nothing")
    func secondStartFails() async throws {
        let (_, open) = AsyncStream<Void>.makeStream()
        open.finish()
        let recorder = MicDictationRecorder(
            model: "openai_whisper-large-v3_turbo",
            language: nil,
            streamingEnabled: true,
            makeStreamingSession: { SpySession(text: "x", stopGate: AsyncStream { $0.finish() }) },
            warmFallbackModel: { _ in }
        )
        try await recorder.start()

        await #expect(throws: (any Error).self) { try await recorder.start() }
        await recorder.stopAndDiscard()
    }
}

@MainActor
@Suite("Dictation target and clipboard")
struct DictationTargetTests {
    private func freshPasteboard() -> NSPasteboard {
        let pasteboard = NSPasteboard.withUniqueName()
        pasteboard.clearContents()
        return pasteboard
    }

    // @unchecked: `items` is touched only under `lock`.
    private final class Landed: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [String] = []
        var texts: [String] { lock.withLock { items } }
        func add(_ text: String) { lock.withLock { items.append(text) } }
    }

    private struct Recording: TextInserter {
        let landed: Landed
        func insert(_ text: String) async throws { landed.add(text) }
    }

    @Test("a take lands in the app it was dictated into")
    func sameAppInserts() async throws {
        let landed = Landed()
        let pasteboard = freshPasteboard()
        var inserter = TargetedTextInserter(base: Recording(landed: landed), target: DictationTarget(processID: 41))
        inserter.frontmostProcessID = { 41 }
        inserter.pasteboardName = pasteboard.name

        try await inserter.insert("hello")

        #expect(landed.texts == ["hello"])
        #expect(pasteboard.string(forType: .string) == nil)
    }

    @Test("a switched app gets the clipboard notice instead of the text")
    func switchedAppCopiesAndFails() async {
        let landed = Landed()
        let pasteboard = freshPasteboard()
        var inserter = TargetedTextInserter(base: Recording(landed: landed), target: DictationTarget(processID: 41))
        inserter.frontmostProcessID = { 99 }
        inserter.pasteboardName = pasteboard.name

        await #expect(throws: TextInsertionError.self) { try await inserter.insert("hello") }

        #expect(landed.texts.isEmpty)
        #expect(pasteboard.string(forType: .string) == "hello")
        #expect(TextInsertionError.targetChanged.errorDescription == "Copied: you switched apps")
    }

    @Test("the cleanup prompt follows the take's own app, not the one in front")
    func promptFollowsTheTarget() async {
        let mail = Prompt(name: "Mail", instructions: "mail")
        let chat = Prompt(name: "Chat", instructions: "chat")
        let used = OSAllocatedUnfairLock<[String]>(initialState: [])
        let template = PromptDictationProcessor(
            defaultPrompt: nil,
            overrides: ["com.mail": [DictationOverrideEntry(prompt: mail, urlPattern: nil)],
                        "com.chat": [DictationOverrideEntry(prompt: chat, urlPattern: nil)]],
            cleanupRunner: { prompt, input in
                used.withLock { $0.append(prompt.name) }
                return input
            }
        )

        _ = await template.targeting(DictationTarget(processID: 1, bundleID: "com.mail", appName: "Mail")).process("hi there")
        _ = await template.targeting(DictationTarget(processID: 2, bundleID: "com.chat", appName: "Chat")).process("hi there")

        #expect(used.withLock { $0 } == ["Mail", "Chat"])
    }

    @Test("a take's binding takes its insertion mode and delay from its own target")
    func bindingFollowsTheTargetWorkflow() {
        let model = AppModel(skipBootstrap: true, defaults: temporaryDefaults(), libraryURL: makeTempLibraryURL("target"))
        model.dictationPerAppOverridesJSON = "{}"
        model.setDictationOverrideInsertion(.keystroke, for: "com.typed")
        model.dictationPasteDelayMs = 300
        let bind = model.dictationPipelineConfiguration().bind

        let typed = (bind?(DictationTarget(processID: 1, bundleID: "com.typed")).inserter as? TargetedTextInserter)
        let pasted = (bind?(DictationTarget(processID: 2, bundleID: "com.other")).inserter as? TargetedTextInserter)

        #expect(typed?.base is KeystrokeTextInserter)
        #expect(pasted?.base is ClipboardPasteInserter)
        #expect(pasted?.pasteDelayMs == 300)
        #expect(typed?.pasteDelayMs == 0)
        #expect(typed?.target?.processID == 1)
    }

    @Test("a pending clipboard restore keeps the user's text readable, not the pasted take")
    func clipboardReadsSkipThePastedText() async throws {
        let pasteboard = freshPasteboard()
        pasteboard.setString("mine", forType: .string)
        let inserter = ClipboardPasteInserter(
            trustCheck: { true }, pasteboardName: pasteboard.name, restoreDelay: .seconds(600), postPaste: {}
        )

        try await inserter.insert("dictated")

        #expect(pasteboard.string(forType: .string) == "dictated")
        #expect(PendingPasteRestores.userText(on: pasteboard.name) == "mine")
        _ = PendingPasteRestores.takeReusablePrior(on: pasteboard.name)
    }
}

private struct PassThrough: TextPostProcessor {
    func process(_ text: String) async -> String { text }
}

private struct ScopedSource: DictationContextSource {
    let pid: Int32
    func currentSelection() async -> String? { "selected in \(pid)" }
    func clipboardContents() async -> String? { nil }
    func windowOCR() async -> String? { "window of \(pid)" }
}

@MainActor
@Suite("Dictation context scope and clipboard call sites")
struct DictationContextScopeTests {
    @Test("a selection owned by another app is never taken")
    func selectionOwnerMustBeTheTarget() {
        #expect(MacContextSource.accepts(owner: 10, target: 10))
        #expect(!MacContextSource.accepts(owner: 11, target: 10))
        #expect(MacContextSource.accepts(owner: 11, target: nil))
    }

    @Test("a take's cleanup prompt carries context from its own app only")
    func promptContextFollowsTheTarget() async {
        let seen = OSAllocatedUnfairLock<[String]>(initialState: [])
        var template = PromptDictationProcessor(
            defaultPrompt: Prompt(name: "Cleanup", instructions: "clean"),
            overrides: [:],
            contextProvider: DictationContextProvider(source: ScopedSource(pid: 999)),
            contextConfig: DictationContextConfig(selectionEnabled: true, screenEnabled: true),
            cleanupRunner: { prompt, input in
                seen.withLock { $0.append(prompt.instructions) }
                return input
            }
        )
        template.scopedContext = { DictationContextProvider(source: ScopedSource(pid: $0)) }

        _ = await template.targeting(DictationTarget(processID: 7, bundleID: "com.a")).process("hello there")

        let instructions = seen.withLock { $0 }.first ?? ""
        #expect(instructions.contains("selected in 7"))
        #expect(instructions.contains("window of 7"))
        #expect(!instructions.contains("999"))
    }

    @Test("both clipboard call sites read the user's text while a paste restore is pending")
    func clipboardCallSitesSkipThePastedText() async throws {
        let pasteboard = NSPasteboard.withUniqueName()
        pasteboard.clearContents()
        pasteboard.setString("mine", forType: .string)
        let inserter = ClipboardPasteInserter(
            trustCheck: { true }, pasteboardName: pasteboard.name, restoreDelay: .seconds(600), postPaste: {}
        )
        try await inserter.insert("dictated")

        let snippet = NSPasteboardClipboardReader(pasteboardName: pasteboard.name).currentText()
        let context = await MacContextSource(clipboardName: pasteboard.name).clipboardContents()

        #expect(snippet == "mine")
        #expect(context == "mine")
        _ = PendingPasteRestores.takeReusablePrior(on: pasteboard.name)
    }

    @Test("the paste delay runs before the target check, so a switch during it is caught")
    func targetCheckFollowsThePasteDelay() async {
        let front = OSAllocatedUnfairLock<Int32>(initialState: 41)
        let pasteboard = NSPasteboard.withUniqueName()
        pasteboard.clearContents()
        var inserter = TargetedTextInserter(
            base: ClipboardPasteInserter(trustCheck: { true }, pasteboardName: pasteboard.name, postPaste: {}),
            target: DictationTarget(processID: 41), pasteDelayMs: 500
        )
        inserter.frontmostProcessID = { front.withLock { $0 } }
        inserter.sleep = { _ in front.withLock { $0 = 99 } }
        inserter.pasteboardName = pasteboard.name

        await #expect(throws: TextInsertionError.self) { try await inserter.insert("hello") }

        #expect(pasteboard.string(forType: .string) == "hello")
    }

    @Test("the recorder's default session carries its decode serializer")
    func defaultSessionCarriesTheSerializer() {
        let serializer = DecodeSerializer()

        let session = MicDictationRecorder.makeDefaultSession(
            clock: ContinuousClock(), deviceUID: nil, serializer: serializer
        ) as? StreamingTranscriptionSession

        #expect(session?.decodesThrough(serializer) == true)
    }

    @Test("one recorder hands every take the same decode serializer, and another recorder its own")
    func recorderOwnsItsSerializer() async throws {
        let seen = OSAllocatedUnfairLock<[ObjectIdentifier]>(initialState: [])
        func make() -> MicDictationRecorder {
            MicDictationRecorder(
                model: "openai_whisper-large-v3_turbo",
                language: nil,
                streamingEnabled: true,
                makeSerializedSession: { _, serializer in
                    seen.withLock { $0.append(ObjectIdentifier(serializer)) }
                    return SpySession(text: "x", stopGate: AsyncStream { $0.finish() })
                },
                warmFallbackModel: { _ in }
            )
        }
        let one = make()
        try await one.start()
        await one.stopAndDiscard()
        try await one.start()
        await one.stopAndDiscard()
        let two = make()
        try await two.start()
        await two.stopAndDiscard()

        let ids = seen.withLock { $0 }
        #expect(ids.count == 3)
        #expect(ids[0] == ids[1])
        #expect(ids[0] != ids[2])
    }
}

@MainActor
@Suite("Dictation settings reload")
struct DictationReloadTests {
    // @unchecked: `made` is touched only under `lock`.
    private final class Monitors: @unchecked Sendable {
        private let lock = NSLock()
        private var made = 0
        var count: Int { lock.withLock { made } }
        func note() { lock.withLock { made += 1 } }
    }

    private final class QuietMonitor: HotkeyMonitor {
        func start(handler: @escaping @Sendable (HotkeyEvent) -> Void) async {}
        func stop() async {}
    }

    private func armedModel(_ defaults: UserDefaults, monitors: Monitors) -> AppModel {
        let model = AppModel(skipBootstrap: true, defaults: defaults, libraryURL: makeTempLibraryURL("reload"))
        model.dictationPerAppOverridesJSON = "{}"
        model.dictationController.hotkeyFactory = { _, _ in
            monitors.note()
            return QuietMonitor()
        }
        model.dictationController.inserterFactory = { CapturingTextInserter(store: CapturedInsertionStore()) }
        model.dictationEnabled = true
        return model
    }

    @Test("an unchanged reload leaves the monitor alone")
    func unchangedReloadDoesNotRestart() {
        let defaults = temporaryDefaults()
        let monitors = Monitors()
        let model = armedModel(defaults, monitors: monitors)

        model.reloadSettings()
        model.reapplyDictationAfterReload()

        #expect(monitors.count == 1)
        model.abortDictation()
    }

    @Test("a reload that changes the mode rebuilds the monitor with it")
    func reloadAppliesTheMode() {
        let defaults = temporaryDefaults()
        let monitors = Monitors()
        let model = armedModel(defaults, monitors: monitors)

        defaults.set(DictationMode.toggle.rawValue, forKey: "dictationModeRaw")
        model.reloadSettings()
        model.reapplyDictationAfterReload()

        #expect(monitors.count == 2)
        #expect(model.dictationController.configuration?.mode == .toggle)
        model.abortDictation()
    }

    @Test("a reload that changes the key rebuilds the monitor")
    func reloadAppliesTheKey() {
        let defaults = temporaryDefaults()
        let monitors = Monitors()
        let model = armedModel(defaults, monitors: monitors)

        defaults.set(97, forKey: "dictationKeyCode")
        model.reloadSettings()
        model.reapplyDictationAfterReload()

        #expect(monitors.count == 2)
        #expect(model.dictationController.configuration?.hotkeyKeyCode == 97)
        model.abortDictation()
    }

    @Test("a reload applies the indicator style without a restart")
    func reloadAppliesTheIndicatorStyle() {
        let defaults = temporaryDefaults()
        let monitors = Monitors()
        let model = armedModel(defaults, monitors: monitors)
        let other = DictationIndicatorStyle.allCases.first { $0 != model.dictationIndicatorStyle }

        defaults.set(other?.rawValue, forKey: "dictationIndicatorStyleRaw")
        model.reloadSettings()
        model.reapplyDictationAfterReload()

        #expect(monitors.count == 1)
        #expect(model.dictationController.indicatorStyle == other)
        model.abortDictation()
    }

    @Test("an accessibility grant re-arms the monitor")
    func grantRestartsTheMonitor() {
        let monitors = Monitors()
        let model = armedModel(temporaryDefaults(), monitors: monitors)
        model.wireDictationController()

        model.dictationPermissions.onAccessibilityGranted?()

        #expect(monitors.count == 2)
        model.abortDictation()
    }

    @Test("a press records the model it used, so turning dictation off unloads that one")
    func pressRecordsTheModel() {
        let model = AppModel(skipBootstrap: true, defaults: temporaryDefaults(), libraryURL: makeTempLibraryURL("pressed"))
        model.selectedModel = "openai_whisper-tiny"

        _ = model.pressedPipelineConfiguration()
        model.selectedModel = "openai_whisper-base"

        #expect(model.lastDictationModel == "openai_whisper-tiny")
    }
}
