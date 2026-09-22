import Foundation
import Testing
@testable import Parola
import ParolaCore
import ParolaTestSupport

@MainActor
@Suite("Send To destinations")
struct SendToPaneTests {

    private func makeModel(features: Set<ParolaFeature> = Set(ParolaFeature.allCases)) -> AppModel {
        AppModel(
            skipBootstrap: true,
            defaults: temporaryDefaults(),
            libraryURL: makeTempLibraryURL("sendto"),
            features: features
        )
    }

    private func obsidian(name: String, autoSend: Bool = false) -> AnyDestination {
        .obsidianFolder(
            ObsidianVaultFolderDestination(
                name: name,
                autoSend: autoSend,
                vaultBookmark: Data([0x01]),
                vaultPath: "/tmp/parola-sendto/\(name)"
            )
        )
    }

    @Test("the list round-trips through the defaults key")
    func roundTripsThroughDefaults() {
        let defaults = temporaryDefaults()
        let library = makeTempLibraryURL("sendto")
        let first = AppModel(skipBootstrap: true, defaults: defaults, libraryURL: library)
        first.setDestinations([obsidian(name: "Vault", autoSend: true)])

        let second = AppModel(skipBootstrap: true, defaults: defaults, libraryURL: library)
        second.loadDestinations()

        #expect(second.destinations.count == 1)
        #expect(second.destinations.first?.name == "Vault")
        #expect(second.destinations.first?.autoSend == true)
        guard case .obsidianFolder(let destination)? = second.destinations.first else {
            Issue.record("expected an Obsidian destination")
            return
        }
        #expect(destination.vaultPath == "/tmp/parola-sendto/Vault")
    }

    @Test("add, update, remove and move all go through setDestinations")
    func listEditing() {
        let model = makeModel()
        let a = obsidian(name: "A")
        let b = obsidian(name: "B")

        model.addDestination(a)
        model.addDestination(b)
        #expect(model.destinations.map(\.name) == ["A", "B"])

        model.moveDestination(id: b.id, by: -1)
        #expect(model.destinations.map(\.name) == ["B", "A"])

        model.moveDestination(id: b.id, by: -1)
        #expect(model.destinations.map(\.name) == ["B", "A"], "a move off the end changes nothing")

        guard case .obsidianFolder(var edited) = a else {
            Issue.record("the destination the test built is not an obsidianFolder")
            return
        }
        edited.name = "A renamed"
        model.updateDestination(.obsidianFolder(edited))
        #expect(model.destinations.map(\.name) == ["B", "A renamed"])

        model.removeDestination(id: b.id)
        #expect(model.destinations.map(\.name) == ["A renamed"])
        #expect(model.readJSON([AnyDestination].self, forKey: "destinations")?.count == 1)
    }

    @Test("updating a destination the list does not hold adds it")
    func updateAddsWhenMissing() {
        let model = makeModel()
        model.updateDestination(obsidian(name: "New"))
        #expect(model.destinations.map(\.name) == ["New"])
    }

    @Test("a kind this build cannot run stays in the list and is never offered")
    func unsupportedIsKeptButNotOffered() {
        let model = makeModel()
        let raw = #"[{"kind":"notion","config":{"id":"6C9C1E1E-0000-0000-0000-0000000000AA","token":"x"}}]"#
        let stored = try! JSONDecoder().decode([AnyDestination].self, from: Data(raw.utf8))
        model.setDestinations(stored + [obsidian(name: "Vault")])

        #expect(model.destinations.count == 2)
        #expect(model.sendableDestinations.map(\.name) == ["Vault"])
    }

    @Test("a destination that is switched off is not offered in the menus")
    func disabledIsNotOffered() {
        let model = makeModel()
        var destination = ObsidianVaultFolderDestination(
            name: "Off", vaultBookmark: Data([0x01]), vaultPath: "/tmp/off"
        )
        destination.isEnabled = false
        model.setDestinations([.obsidianFolder(destination)])
        #expect(model.sendableDestinations.isEmpty)
    }

    @Test("with the feature off the list stays empty and nothing is written")
    func featureOffKeepsTheListEmpty() {
        let model = makeModel(features: Set(ParolaFeature.allCases).subtracting([.destinations]))
        model.setDestinations([obsidian(name: "Vault")])
        #expect(model.destinations.isEmpty)
        #expect(model.readJSON([AnyDestination].self, forKey: "destinations") == nil)
        #expect(!model.destinationsEnabled)
        #expect(model.sendableDestinations.isEmpty)
    }

    @Test("the pane's reset scope clears the stored list")
    func resetScope() {
        #expect(SettingsPaneScope.sendTo.defaultsKeys == ["destinations"])
        #expect(SettingsRoute.sendTo.isVisible(features: .all))
        #expect(!SettingsRoute.sendTo.isVisible(
            features: FeatureSet(enabled: Set(ParolaFeature.allCases).subtracting([.destinations]))
        ))
    }

    @Test("the sample note the editor sends carries text in both segments")
    func samplePayload() {
        let payload = AppModel.sampleDeliveryPayload()
        #expect(payload.transcript.segments.count == 2)
        #expect(payload.speakers.count == 2)
        #expect(!payload.title.isEmpty)
    }

    @Test("the test note lands in the folder the editor is pointing at")
    func testNoteWritesIntoTheVault() async throws {
        let model = makeModel()
        let vault = FileManager.default.temporaryDirectory
            .appendingPathComponent("parola-testnote-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: vault) }
        let destination = ObsidianVaultFolderDestination(
            name: "Vault",
            vaultBookmark: try ObsidianVaultFolderDestination.bookmark(for: vault),
            vaultPath: vault.path,
            subfolder: "Inbox"
        )

        guard case .written(let url) = await model.sendTestNote(to: destination) else {
            Issue.record("expected the test note to be written")
            return
        }
        let written = try #require(url)
        #expect(written.lastPathComponent.hasSuffix(".md"))
        let note = try String(contentsOf: written, encoding: .utf8)
        #expect(note.contains("## Transcript"))
        #expect(await model.library.list().isEmpty, "a test note never touches the library")
    }

    @Test("a test note reports the reason when the folder is gone")
    func testNoteFailureIsReported() async throws {
        let model = makeModel()
        let vault = FileManager.default.temporaryDirectory
            .appendingPathComponent("parola-testnote-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)
        let destination = ObsidianVaultFolderDestination(
            name: "Vault",
            vaultBookmark: try ObsidianVaultFolderDestination.bookmark(for: vault),
            vaultPath: vault.path
        )
        try FileManager.default.removeItem(at: vault)

        guard case .failed(let message) = await model.sendTestNote(to: destination) else {
            Issue.record("expected the test note to fail")
            return
        }
        #expect(!message.isEmpty)
    }

    @Test("a queue under a library override stays out of Application Support")
    func queueFollowsTheLibrary() {
        let model = makeModel()
        #expect(model.deliveryDirectory.path.hasPrefix(model.library.libraryURL.path))
        #expect(model.deliveryDirectory.lastPathComponent == "Delivery")
    }
}
