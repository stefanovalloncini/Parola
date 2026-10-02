import AppKit
import Foundation
import Testing
@testable import Parola
import ParolaCore
import ParolaTestSupport

@MainActor
@Suite("Record while a take runs", .serialized)
struct RecordDuringTakeTests {
    private func recordItems(_ snapshot: MenuBarController.MenuSnapshot) -> [String: Bool] {
        let items = MenuBarController.items(for: snapshot, target: nil)
        let meeting = items.first { $0.title == "Record Meeting" }
        var found = ["Record Meeting": meeting?.isEnabled ?? false]
        for item in meeting?.submenu?.items ?? [] { found[item.title] = item.isEnabled }
        return found
    }

    @Test("the menu bar's Record items are off while a take runs and back once it ends")
    func menuBarRecordItems() throws {
        let wav = try tempWAV("record-during-take-menu")
        defer { try? FileManager.default.removeItem(at: wav) }
        let model = makeRecordingModel("record-during-take-menu")
        model.showMenuBarExtra = true
        model.detectedMeetingAppName = "Zoom"
        let before = MenuBarController.snapshot(for: model)
        #expect(recordItems(before) == ["Record Meeting": true, "Record Zoom": true, "Record System Audio": true, "Record Microphone": true])

        model.installTestTake(source: .systemAudio, liveSource: StubSource(url: wav))
        let during = MenuBarController.snapshot(for: model)

        #expect(before != during, "the menu bar's Record items look the same while a take runs")
        #expect(recordItems(during) == ["Record Meeting": false, "Record Zoom": false, "Record System Audio": false, "Record Microphone": false])
        model.endTestTake()
        #expect(MenuBarController.snapshot(for: model) == before)
    }

    @Test("a mic-only build's Record Microphone is off while a take runs")
    func micOnlyRecordItem() {
        var snapshot = MenuBarController.MenuSnapshot(
            mode: .full, dictateTitle: "", showsDictation: false, showsMicRecording: true, showsSystemAudio: false
        )
        snapshot.canRecordMicrophone = false
        let mic = MenuBarController.items(for: snapshot, target: nil).first { $0.title == "Record Microphone" }
        #expect(mic?.isEnabled == false)
    }

    @Test("a bound menu bar follows the take as it starts and ends")
    func boundMenuFollowsTheTake() async throws {
        let wav = try tempWAV("record-during-take-bound")
        defer { try? FileManager.default.removeItem(at: wav) }
        let model = makeRecordingModel("record-during-take-bound")
        model.showMenuBarExtra = true
        let controller = MenuBarController()
        controller.bind(model)
        let ready = await waitUntil { controller.lastSnapshot?.canRecordMicrophone == true }
        #expect(ready)

        model.installTestTake(source: .microphone, liveSource: StubSource(url: wav))
        let blocked = await waitUntil { controller.lastSnapshot?.canRecordMicrophone == false }
        #expect(blocked)

        model.endTestTake()
        let back = await waitUntil { controller.lastSnapshot?.canRecordMicrophone == true }
        #expect(back)
        model.showMenuBarExtra = false
        _ = await waitUntil { controller.lastSnapshot?.mode == .hidden }
    }

    @Test("an empty Transcriptions or Meetings page's Record waits for the take, its other actions don't")
    func emptyPageActions() throws {
        let wav = try tempWAV("record-during-take-empty")
        defer { try? FileManager.default.removeItem(at: wav) }
        let model = makeRecordingModel("record-during-take-empty")
        let actions: [LibraryEmptyAction] = [.recordMicrophone, .recordSystemAudio, .openFile, .meetingSettings]
        #expect(actions.map { LibraryListContent.isAvailable($0, in: model) } == [true, true, true, true])

        model.installTestTake(source: .microphone, liveSource: StubSource(url: wav))

        #expect(actions.map { LibraryListContent.isAvailable($0, in: model) } == [false, false, true, true])
        model.endTestTake()
    }
}
