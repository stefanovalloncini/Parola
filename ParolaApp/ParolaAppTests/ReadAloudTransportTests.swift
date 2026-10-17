import AppKit
import Foundation
import ParolaCore
import ParolaSpeech
import SwiftUI
import Testing
@testable import Parola
import ParolaTestSupport

@MainActor
@Suite("Read Aloud transport")
struct ReadAloudTransportTests {
    @Test("Pause/Resume, Previous, Skip and Stop follow the state, the block and whether a sentence has started", arguments: [
        (ReadAloudController.State.idle, nil as ReadAloudController.BlockedReason?, false, false, false, false),
        (.noVoice("fa"), nil, false, false, false, false),
        (.preparing, nil, false, true, false, true),
        (.preparing, nil, true, true, false, true),
        (.reading, nil, true, true, true, true),
        (.reading, .take, true, true, false, true),
        (.waiting(.slow), nil, true, true, true, true),
        (.paused(.user), nil, true, true, true, true),
        (.paused(.user), nil, false, true, false, true),
        (.paused(.take), .take, true, false, false, true),
        (.paused(.media), nil, true, true, true, true),
        (.failed("x"), nil, false, false, false, true),
    ] as [(ReadAloudController.State, ReadAloudController.BlockedReason?, Bool, Bool, Bool, Bool)])
    func table(
        state: ReadAloudController.State, blocked: ReadAloudController.BlockedReason?, started: Bool,
        toggle: Bool, step: Bool, stop: Bool
    ) {
        let transport = ReadingTransport.resolve(state: state, blocked: blocked, sentenceStarted: started)
        #expect(transport.toggleEnabled == toggle)
        #expect(transport.stepEnabled == step)
        #expect(transport.stopEnabled == stop)
    }

    @Test("a block carries its reason on every disabled item, in English and Italian", arguments: [
        (ReadAloudController.BlockedReason.take, "Reading waits until the recording ends.", "La lettura attende la fine della registrazione."),
        (.dictation, "Reading waits until dictation ends.", "La lettura attende la fine della dettatura."),
        (.captions, "Reading waits until live captions stop.", "La lettura attende la fine dei sottotitoli in tempo reale."),
    ] as [(ReadAloudController.BlockedReason, String, String)])
    func blockedReasons(reason: ReadAloudController.BlockedReason, english: String, italian: String) throws {
        let transport = ReadingTransport.resolve(state: .paused(reason.pauseReason), blocked: reason, sentenceStarted: true)
        #expect(transport.blockedMessage == english)
        #expect(ReadingTransport.resolve(state: .reading, blocked: nil, sentenceStarted: true).blockedMessage == nil)
        let path = try #require(Bundle.main.path(forResource: "it", ofType: "lproj"))
        let bundle = try #require(Bundle(path: path))
        #expect(bundle.localizedString(forKey: english, value: "MISSING", table: nil) == italian)
    }

    @Test("the one toggle item reads Pause Reading while it plays and Resume Reading otherwise")
    func toggleTitles() {
        #expect(ReadingTransport.resolve(state: .reading, blocked: nil, sentenceStarted: true).toggleTitle == "Pause Reading")
        #expect(ReadingTransport.resolve(state: .preparing, blocked: nil, sentenceStarted: false).toggleTitle == "Pause Reading")
        #expect(ReadingTransport.resolve(state: .paused(.user), blocked: nil, sentenceStarted: true).toggleTitle == "Resume Reading")
        #expect(ReadingTransport.resolve(state: .waiting(.slow), blocked: nil, sentenceStarted: true).toggleTitle == "Resume Reading")
    }

    @Test("Previous restarts the sentence once more than 1.5 s of it has played, else goes back one")
    func previousRule() async {
        let rig = ReadAloudRig()
        await rig.start(ReadAloudRig.plan(units: 3))
        await rig.finishUnit()
        await waitUntil { rig.controller.item?.unitIndex == 1 }

        await rig.controller.skip(by: -1)
        await waitUntil { rig.controller.item?.unitIndex == 0 }
        #expect(rig.controller.item?.unitIndex == 0)

        await rig.controller.skip(by: 1)
        await waitUntil { rig.controller.item?.unitIndex == 1 }
        let before = rig.sink.calls.filter { $0 == .schedule(unitID: 1) }.count
        rig.clock.advance(by: .seconds(2))
        await settle()
        await rig.controller.skip(by: -1)
        await waitUntil { rig.sink.calls.filter { $0 == .schedule(unitID: 1) }.count > before }
        #expect(rig.sink.calls.filter { $0 == .schedule(unitID: 1) }.count > before)
        #expect(rig.controller.item?.unitIndex == 1)
    }

    @Test("Use Built-in Voice retries from the failed unit with apple:auto and saves nothing")
    func builtInRetry() async throws {
        let rig = ReadAloudRig(failAtUnit: 1)
        var plan = ReadAloudRig.plan()
        plan.voice = try #require(VoiceID.apple(identifier: "com.example.voice"))
        await rig.start(plan)
        await rig.finishUnit()
        await waitUntil { rig.controller.state.name == "failed" }
        #expect(rig.controller.item?.unitIndex == 1)

        await rig.renderer.setFailAtUnit(nil)
        await rig.controller.retry(using: .appleAutomatic)
        await waitUntil { rig.controller.state == .reading }

        #expect(rig.controller.item?.voice == .appleAutomatic)
        #expect(rig.controller.item?.unitIndex == 1)
    }

    @Test("the model's built-in retry leaves the saved voices alone")
    func builtInRetrySavesNothing() async throws {
        let model = AppModel(skipBootstrap: true, defaults: temporaryDefaults(), libraryURL: makeTempLibraryURL("builtin-retry"))
        model.transcript = EntryWindowTestSupport.transcript(texts: ["One two three four.", "Five six seven eight."], speakers: [])
        model.phase = .ready
        model.readAloudVoices = ["en": try #require(VoiceID.apple(identifier: "com.parola.mock.en.premium"))]
        let saved = model.readAloudVoices
        model.readAloud.mockVoice?.install(msPerUnit: 20, failAtUnit: 1)
        await model.readAloud(ReadAloudRequest(kind: .transcript))
        await waitUntil { model.readAloud.state.name == "failed" }
        #expect(model.readAloud.item?.voice != .appleAutomatic)

        model.readAloud.mockVoice?.install(msPerUnit: 60_000, failAtUnit: nil)
        await model.retryReadingWithBuiltInVoice()
        await waitUntil { model.readAloud.state == .reading }

        #expect(model.readAloudVoices == saved)
        #expect(model.readAloud.item?.voice == .appleAutomatic)
        #expect(model.readAloud.item?.unitIndex == 1)
        await model.stopReading()
    }
}

@MainActor
@Suite("Read Aloud Playback menu")
struct ReadAloudPlaybackMenuTests {
    private func items(_ model: AppModel) -> [NSMenuItem] {
        let menu = NSHostingMenu(rootView: PlaybackCommands(model: model))
        menu.update()
        return menu.items
    }

    private func seeded(_ label: String) async throws -> (AppModel, LibraryEntry) {
        let model = EntryWindowTestSupport.makeModel(label)
        let entry = try await EntryWindowTestSupport.seed(
            model, texts: ["One two three four.", "Five six seven eight."], speakers: [nil, nil], audio: nil
        )
        return (model, entry)
    }

    @Test("the Playback menu carries the reading section after the player items, with its ids and Read Aloud on ⌥⌘R")
    func menuSection() async throws {
        let (model, _) = try await seeded("pm-section")
        let all = items(model)
        let titles = all.map { $0.isSeparatorItem ? "—" : $0.title }
        #expect(titles.suffix(6) == ["—", "Read Aloud", "Pause Reading", "Previous Sentence", "Skip Sentence", "Stop Reading"], "\(titles)")
        let read = try #require(all.first { $0.title == "Read Aloud" })
        #expect(read.keyEquivalent == "r")
        #expect(read.keyEquivalentModifierMask == [.command, .option])
        #expect(Array(titles.prefix(3)) == ["Play", "Skip Back 5 Seconds", "Skip Forward 5 Seconds"])
    }

    @Test("with nothing reading only Read Aloud can be on, and the rest wait")
    func idleEnablement() async throws {
        let (model, entry) = try await seeded("pm-idle")
        model.loadEntry(entry.id)
        await waitUntil { model.hasTranscript }
        let all = items(model)
        func enabled(_ title: String) -> Bool { all.first { $0.title == title }?.isEnabled ?? false }
        #expect(enabled("Read Aloud"))
        #expect(!enabled("Pause Reading"))
        #expect(!enabled("Previous Sentence"))
        #expect(!enabled("Skip Sentence"))
        #expect(!enabled("Stop Reading"))
    }

    @Test("Read Aloud on the same entry pauses, then resumes, never restarts; on another entry it replaces")
    func stateMapping() async throws {
        let (model, entry) = try await seeded("pm-map")
        model.loadEntry(entry.id)
        await waitUntil { model.hasTranscript }
        let other = try await EntryWindowTestSupport.seed(model, texts: ["Nine ten eleven twelve."], speakers: [nil], audio: nil)

        await model.readAloudFromMenu()
        await waitUntil { model.readAloud.state == .reading }
        let started = model.readAloud.item
        #expect(started?.entryID == entry.id)

        await model.readAloudFromMenu()
        #expect(model.readAloud.state == .paused(.user))
        #expect(model.readAloud.item == started)

        await model.readAloudFromMenu()
        #expect(model.readAloud.state == .reading)
        #expect(model.readAloud.item?.unitIndex == started?.unitIndex)

        model.loadEntry(other.id)
        await waitUntil { model.selectedEntryID == other.id && model.hasTranscript }
        await model.readAloudFromMenu()
        await waitUntil { model.readAloud.item?.entryID == other.id }
        #expect(model.readAloud.item?.entryID == other.id)
        await model.stopReading()
    }

    @Test("a failed reading of this entry retries from the failed unit, not from the top")
    func failedRetries() async throws {
        let model = EntryWindowTestSupport.makeModel("pm-failed")
        let entry = try await EntryWindowTestSupport.seed(
            model, texts: ["One two three four.", "Five six seven eight.", "Nine ten eleven twelve."],
            speakers: [nil, nil, nil], audio: nil
        )
        model.loadEntry(entry.id)
        await waitUntil { model.hasTranscript }
        model.readAloud.mockVoice?.install(msPerUnit: 20, failAtUnit: 1)
        await model.readAloudFromMenu()
        await waitUntil { model.readAloud.state.name == "failed" }
        #expect(model.readAloud.item?.unitIndex == 1)

        model.readAloud.mockVoice?.install(msPerUnit: 60_000, failAtUnit: nil)
        await model.readAloudFromMenu()
        await waitUntil { model.readAloud.state == .reading }
        #expect(model.readAloud.item?.unitIndex == 1)
        await model.stopReading()
    }

    @Test("with a viewer window key, Read Aloud reads that window's entry from the top")
    func viewerRouting() async throws {
        let (model, entry) = try await seeded("pm-viewer")
        let main = try await EntryWindowTestSupport.seed(model, texts: ["Alpha beta gamma delta."], speakers: [nil], audio: nil)
        model.loadEntry(main.id)
        await waitUntil { model.hasTranscript }
        _ = await EntryWindowTestSupport.openSession(model, entry)
        model.entryWindowKeyChanged(entry.id, isKey: true)

        await model.readAloudFromMenu()
        await waitUntil { model.readAloud.state == .reading }

        #expect(model.readAloud.item?.entryID == entry.id)
        #expect(model.readAloud.item?.unitCount == 2)
        await model.stopReading()
    }

    @Test("a viewer-window reading that needs a voice opens the chooser on that window")
    func viewerChooser() async throws {
        let (model, entry) = try await seeded("pm-viewer-chooser")
        _ = await EntryWindowTestSupport.openSession(model, entry)
        model.entryWindowKeyChanged(entry.id, isKey: true)
        model.readAloudVoices = ["en": try #require(VoiceID.apple(identifier: "com.example.gone"))]

        await model.readAloudFromMenu()

        let prompt = try #require(model.readAloud.voicePrompt)
        #expect(prompt.origin == .entryWindow(entry.id))
        #expect(prompt.request?.entryID == entry.id)
        #expect(model.readAloud.state == .idle)
    }

    @Test("a take pauses the reading, disables its items with the reason, and hides the control")
    func blocked() async throws {
        let (model, entry) = try await seeded("pm-blocked")
        model.readAloud.mockVoice?.install(msPerUnit: 60_000, failAtUnit: nil)
        model.loadEntry(entry.id)
        await waitUntil { model.hasTranscript }
        await model.readAloudFromMenu()
        await waitUntil { model.readAloud.state == .reading }
        #expect(model.nowReadingLayout == .full || model.nowReadingLayout == .compact)

        model.installTestTake(source: .microphone)
        await waitUntil { model.readAloud.state == .paused(.take) }

        #expect(model.readingBlockedReason == .take)
        let transport = model.readingTransport
        #expect(!transport.stepEnabled)
        #expect(!transport.toggleEnabled)
        #expect(transport.blockedMessage == ReadAloudController.BlockedReason.take.message)
        #expect(model.nowReadingLayout == .hidden)
        #expect(model.readAloudMenuStatus?.isEnabled != true)
        #expect(await model.readAloud(ReadAloudRequest(kind: .transcript)) == .blocked(.take))
        let menu = items(model)
        #expect(menu.first { $0.title == "Skip Sentence" }?.isEnabled == false)
        await model.stopReading()
    }

    @Test("Space, the toolbar and the menus toggle through the model: pause a playing reading, resume a paused one")
    func toggleMapping() async throws {
        let (model, entry) = try await seeded("pm-toggle")
        model.readAloud.mockVoice?.install(msPerUnit: 60_000, failAtUnit: nil)
        model.loadEntry(entry.id)
        await waitUntil { model.hasTranscript }
        await model.readAloudFromMenu()
        await waitUntil { model.readAloud.state == .reading }

        await model.toggleReading()
        #expect(model.readAloud.state == .paused(.user))
        await model.toggleReading()
        await waitUntil { model.readAloud.state == .reading }
        #expect(model.readAloud.state == .reading)
        await model.stopReading()
    }

    @Test("the key router drives a reading: ⌘→ skips, Space pauses, ⌘← goes back")
    func handleDrivesReading() async throws {
        let (model, entry) = try await seeded("pm-keys")
        model.readAloud.mockVoice?.install(msPerUnit: 60_000, failAtUnit: nil)
        model.loadEntry(entry.id)
        await waitUntil { model.hasTranscript }
        await model.readAloudFromMenu()
        await waitUntil { model.readAloud.state == .reading }

        #expect(PlaybackKeyMonitor.handle(keyCode: 124, modifiers: [.command], firstResponder: nil, inMainWindow: true, model: model))
        await waitUntil { model.readAloud.item?.unitIndex == 1 }
        #expect(model.readAloud.item?.unitIndex == 1)
        #expect(PlaybackKeyMonitor.handle(keyCode: 123, modifiers: [.command], firstResponder: nil, inMainWindow: true, model: model))
        await waitUntil { model.readAloud.item?.unitIndex == 0 }
        #expect(model.readAloud.item?.unitIndex == 0)
        #expect(PlaybackKeyMonitor.handle(keyCode: 49, modifiers: [], firstResponder: nil, inMainWindow: true, model: model))
        await waitUntil { model.readAloud.state == .paused(.user) }
        #expect(model.readAloud.state == .paused(.user))
        await model.stopReading()
    }

    @Test("a paused reading's Playback item reads Resume Reading, and Pause Reading while it plays")
    func playbackItemFollowsTheState() async throws {
        let (model, entry) = try await seeded("pm-title")
        model.readAloud.mockVoice?.install(msPerUnit: 60_000, failAtUnit: nil)
        model.loadEntry(entry.id)
        await waitUntil { model.hasTranscript }
        await model.readAloudFromMenu()
        await waitUntil { model.readAloud.state == .reading }
        #expect(items(model).contains { $0.title == "Pause Reading" && $0.isEnabled })

        await model.pauseReading()
        #expect(items(model).contains { $0.title == "Resume Reading" && $0.isEnabled })
        await model.stopReading()
    }

    @Test("the cheat sheet lists Read Aloud ⌥⌘R under Playback")
    func cheatSheet() {
        let playback = ShortcutCatalog.sections(features: .all).first { $0.title == "Playback" }
        let row = playback?.entries.first { $0.label == "Read Aloud" }
        #expect(row?.keys == "⌘ ⌥ R")
    }
}
