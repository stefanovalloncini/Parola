import Foundation
import Testing
import ParolaCore
@testable import Parola

@MainActor
@Suite("Menu bar refresh")
struct MenuBarRefreshTests {
    private static let baseDate = Date(timeIntervalSince1970: 1_700_000_000)

    private func entry(_ id: String, offset: TimeInterval, pinned: Bool = false) -> LibraryEntry {
        let manifest = ParolaDocument.Manifest(
            createdAt: Self.baseDate.addingTimeInterval(offset),
            originalAudioName: "\(id).m4a",
            title: id.uppercased(),
            modelName: "stub",
            language: "en",
            pinned: pinned
        )
        return LibraryEntry(
            id: id,
            bundleURL: URL(fileURLWithPath: "/tmp/MenuBarRefreshTests/\(id).parola"),
            manifest: manifest
        )
    }

    /// AppModel's init kicks off a library refresh; letting it land keeps it from clobbering the seeded entries.
    private func makeModel() async -> AppModel {
        let model = AppModel(
            skipBootstrap: true,
            defaults: temporaryDefaults(),
            libraryURL: makeTempLibraryURL("menubar")
        )
        await model.libraryRefreshTask?.value
        return model
    }

    private func settle(
        _ controller: MenuBarController,
        until matches: (MenuBarController.MenuSnapshot?) -> Bool
    ) async throws {
        for _ in 0..<200 where !matches(controller.lastSnapshot) {
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test("the menu lands on the final state after rapid mutations")
    func rapidMutationsReachFinalState() async throws {
        let model = await makeModel()
        model.showMenuBarExtra = true
        let controller = MenuBarController()
        controller.bind(model)

        model.libraryEntries = [entry("a", offset: 100)]
        model.libraryEntries = [entry("a", offset: 100), entry("b", offset: 200)]
        model.libraryEntries = [entry("a", offset: 100), entry("b", offset: 200), entry("c", offset: 300)]

        try await settle(controller) { $0?.recents.count == 3 }
        #expect(controller.lastSnapshot?.recents.map(\.id) == ["c", "b", "a"])

        model.showMenuBarExtra = false
        try await settle(controller) { $0?.mode == .hidden }
    }

    @Test("a mutation landing between two refreshes still reaches the menu")
    func mutationDuringRefreshWindow() async throws {
        let model = await makeModel()
        model.showMenuBarExtra = true
        let controller = MenuBarController()
        controller.bind(model)

        model.libraryEntries = [entry("a", offset: 100)]
        try await Task.sleep(for: .milliseconds(1))
        model.libraryEntries = [entry("a", offset: 100), entry("b", offset: 200, pinned: true)]

        try await settle(controller) { $0?.pinned.count == 1 }
        #expect(controller.lastSnapshot?.pinned.map(\.id) == ["b"])
        #expect(controller.lastSnapshot?.recents.map(\.id) == ["b", "a"])

        model.showMenuBarExtra = false
        try await settle(controller) { $0?.mode == .hidden }
    }

    @Test("the snapshot lists the newest entries first and caps them")
    func snapshotOrdersRecents() async {
        let model = await makeModel()
        model.showMenuBarExtra = true
        model.libraryEntries = (0..<10).map { entry("e\($0)", offset: TimeInterval($0)) }

        let snapshot = MenuBarController.snapshot(for: model)

        #expect(snapshot.mode == .full)
        #expect(snapshot.recents.map(\.id) == ["e9", "e8", "e7", "e6", "e5", "e4", "e3", "e2"])
        #expect(snapshot.recents.first?.title == "E9")
    }

    @Test("a hidden menu bar skips the entry scan")
    func hiddenModeSkipsEntries() async {
        let model = await makeModel()
        model.libraryEntries = [entry("a", offset: 100, pinned: true)]

        let snapshot = MenuBarController.snapshot(for: model)

        #expect(snapshot.mode == .hidden)
        #expect(snapshot.recents.isEmpty)
        #expect(snapshot.pinned.isEmpty)
    }
}
