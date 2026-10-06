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
        let titles: Set<String> = ["New Recording", "New System Audio Recording", "Record Zoom Meeting"]
        let items = MenuBarController.items(for: snapshot, target: nil).filter { titles.contains($0.title) }
        return Dictionary(uniqueKeysWithValues: items.map { ($0.title, $0.isEnabled) })
    }

    @Test("the menu bar's Record items are off while a take runs and back once it ends")
    func menuBarRecordItems() throws {
        let wav = try tempWAV("record-during-take-menu")
        defer { try? FileManager.default.removeItem(at: wav) }
        let model = makeRecordingModel("record-during-take-menu")
        model.showMenuBarExtra = true
        model.detectedMeetingAppName = "Zoom"
        let before = MenuBarController.snapshot(for: model)
        #expect(recordItems(before) == ["Record Zoom Meeting": true, "New System Audio Recording": true, "New Recording": true])

        model.installTestTake(source: .systemAudio, liveSource: StubSource(url: wav))
        let during = MenuBarController.snapshot(for: model)

        #expect(before != during, "the menu bar's Record items look the same while a take runs")
        #expect(recordItems(during) == ["Record Zoom Meeting": false, "New System Audio Recording": false, "New Recording": false])
        model.endTestTake()
        #expect(MenuBarController.snapshot(for: model) == before)
    }

    @Test("the Dock menu works with the menu bar extra off, and offers Stop Recording while a take runs")
    func dockMenuFollowsTheTake() throws {
        let wav = try tempWAV("record-during-take-dock")
        defer { try? FileManager.default.removeItem(at: wav) }
        let model = makeRecordingModel("record-during-take-dock")
        model.showMenuBarExtra = false
        let controller = MenuBarController()
        controller.bind(model)
        let idle = controller.dockMenu()?.items.map(\.title) ?? []
        #expect(idle.first == "New Recording", "\(idle)")

        model.installTestTake(source: .systemAudio, liveSource: StubSource(url: wav))
        let menu = try #require(controller.dockMenu())
        let stop = try #require(menu.items.first)
        #expect(stop.title == "Stop Recording")
        #expect(!menu.items.map(\.title).contains("New Recording"))
        model.endTestTake()
    }

    @Test("a mic-only build's New Recording is off while a take runs")
    func micOnlyRecordItem() {
        var snapshot = MenuBarController.MenuSnapshot(
            mode: .full, dictateTitle: "", showsDictation: false, showsMicRecording: true, showsSystemAudio: false
        )
        snapshot.canRecordMicrophone = false
        let mic = MenuBarController.items(for: snapshot, target: nil).first { $0.title == "New Recording" }
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
