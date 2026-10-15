import Foundation
import Testing
@testable import ParolaCore

@Suite("Destination envelope coding")
struct AnyDestinationCodableTests {

    func encoded(_ destinations: [AnyDestination]) throws -> Data {
        try JSONEncoder().encode(destinations)
    }

    func decoded(_ data: Data) throws -> [AnyDestination] {
        try JSONDecoder().decode([AnyDestination].self, from: data)
    }

    func obsidian() -> ObsidianVaultFolderDestination {
        ObsidianVaultFolderDestination(
            id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
            name: "Vault",
            isEnabled: true,
            autoSend: true,
            categories: [.meeting, .transcription],
            titleFormat: .dateAndTitle,
            vaultBookmark: Data([0x01, 0x02, 0x03]),
            vaultPath: "/tmp/vault",
            subfolder: "Transcripts",
            filenameTemplate: "{date} {title}",
            collision: .overwrite,
            frontmatter: ObsidianFrontmatterOptions(duration: false),
            body: ObsidianBodyOptions(timestamps: true),
            wikilinks: true
        )
    }

    @Test("an Obsidian destination round-trips through the envelope")
    func obsidianRoundTrips() throws {
        let original = obsidian()
        let restored = try decoded(try encoded([.obsidianFolder(original)]))
        #expect(restored.count == 1)
        guard case .obsidianFolder(let back) = restored[0] else {
            Issue.record("expected an obsidianFolder destination, got \(restored[0])")
            return
        }
        #expect(back == original)
    }

    @Test("the envelope carries the kind next to the config")
    func envelopeShape() throws {
        let data = try encoded([.obsidianFolder(obsidian())])
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        #expect(json.first?["kind"] as? String == "obsidianFolder")
        let config = try #require(json.first?["config"] as? [String: Any])
        #expect(config["subfolder"] as? String == "Transcripts")
        #expect(config["categories"] as? [String] == ["meeting", "transcription"])
    }

    @Test("the envelope exposes what the list rows read")
    func envelopeAccessors() {
        let destination = AnyDestination.obsidianFolder(obsidian())
        #expect(destination.name == "Vault")
        #expect(destination.isEnabled)
        #expect(destination.autoSend)
        #expect(destination.categories == [.meeting, .transcription])
        #expect(destination.titleFormat == .dateAndTitle)
        #expect(destination.kind == .obsidianFolder)
        #expect(destination.id == UUID(uuidString: "11111111-2222-3333-4444-555555555555"))
    }

    @Test("a config from a newer build keeps its known fields and defaults the rest")
    func configForwardCompat() throws {
        let raw = """
        [{"kind":"obsidianFolder","config":{
          "id":"6C9C1E1E-0000-0000-0000-000000000004",
          "name":"Newer",
          "isEnabled":true,
          "autoSend":false,
          "categories":["dictation"],
          "titleFormat":"aiTitle",
          "vaultBookmark":"AQID",
          "vaultPath":"/tmp/vault",
          "subfolder":"",
          "filenameTemplate":"{title}",
          "collision":"appendCounter",
          "somethingFromTheFuture":{"deeply":["nested", 2]}
        }}]
        """
        let restored = try decoded(Data(raw.utf8))
        guard case .obsidianFolder(let back) = restored[0] else {
            Issue.record("expected an obsidianFolder destination, got \(restored[0])")
            return
        }
        #expect(back.name == "Newer")
        #expect(back.categories == [.dictation])
        #expect(back.titleFormat == .aiTitle)
        #expect(back.wikilinks == false)
        #expect(back.frontmatter == ObsidianFrontmatterOptions())
        #expect(back.body == ObsidianBodyOptions())
    }

    @Test("a config the kind cannot decode is kept as unsupported instead of throwing")
    func brokenConfigIsKept() throws {
        let raw = #"[{"kind":"obsidianFolder","config":{"name":42}}]"#
        let restored = try decoded(Data(raw.utf8))
        guard case .unsupported(let kind, _) = restored[0] else {
            Issue.record("expected unsupported, got \(restored[0])")
            return
        }
        #expect(kind == "obsidianFolder")
    }

    @Test("a kind this build does not implement decodes as unsupported and re-encodes unchanged")
    func unknownKindSurvives() throws {
        let raw = """
        [{"kind":"notion","config":{"id":"6C9C1E1E-0000-0000-0000-000000000001","databaseID":"abc","nested":{"n":1}}}]
        """
        let restored = try decoded(Data(raw.utf8))
        guard case .unsupported(let kind, let config) = restored[0] else {
            Issue.record("expected unsupported, got \(restored[0])")
            return
        }
        #expect(kind == "notion")
        #expect(config.object?["databaseID"] == .string("abc"))

        let json = try #require(
            JSONSerialization.jsonObject(with: try encoded(restored)) as? [[String: Any]]
        )
        #expect(json.first?["kind"] as? String == "notion")
        let back = try #require(json.first?["config"] as? [String: Any])
        #expect(back["databaseID"] as? String == "abc")
        #expect((back["nested"] as? [String: Any])?["n"] as? Double == 1)
    }

    @Test("a kind nobody has ever heard of decodes rather than throwing")
    func inventedKindDecodes() throws {
        let raw = #"[{"kind":"telepathy","config":{"id":"6C9C1E1E-0000-0000-0000-000000000002"}}]"#
        let restored = try decoded(Data(raw.utf8))
        #expect(restored.count == 1)
        #expect(restored[0].kind == nil)
        #expect(restored[0].destination == nil)
        #expect(!restored[0].isEnabled)
        #expect(!restored[0].autoSend)
    }

    @Test("an unsupported entry keeps the id its config carries")
    func unsupportedKeepsItsID() throws {
        let raw = #"[{"kind":"webhook","config":{"id":"6C9C1E1E-0000-0000-0000-000000000003"}}]"#
        let restored = try decoded(Data(raw.utf8))
        #expect(restored[0].id == UUID(uuidString: "6C9C1E1E-0000-0000-0000-000000000003"))
        #expect(restored[0].kind == .webhook)
    }

    @Test("an unsupported entry with no id still gets a stable one")
    func unsupportedIDIsStable() throws {
        let raw = #"[{"kind":"webhook","config":{"url":"https://example.invalid/hook"}}]"#
        let first = try decoded(Data(raw.utf8))[0].id
        let second = try decoded(Data(raw.utf8))[0].id
        #expect(first == second)
    }

    @Test("a missing config decodes as an empty one")
    func missingConfigIsEmpty() throws {
        let restored = try decoded(Data(#"[{"kind":"webhook"}]"#.utf8))
        #expect(restored[0].kind == .webhook)
        #expect(restored[0].destination == nil)
    }

    @Test("a mock destination is kept out of the stored list")
    func mocksAreNotPersisted() {
        let list: [AnyDestination] = [.obsidianFolder(obsidian()), .mock(MockDestination(name: "Mock vault"))]
        #expect(list.filter(\.isPersistable).map(\.name) == ["Vault"])
        #expect(AnyDestination.unsupported(kind: "notion", config: .object([:])).isPersistable)
    }

    @Test("every destination kind has a stable raw value")
    func kindRawValues() {
        #expect(DestinationKind.allCases.map(\.rawValue) == [
            "obsidianFolder", "obsidianREST", "webhook", "notion",
        ])
        #expect(DestinationKind.allCases.filter(\.isImplemented) == DestinationKind.allCases)
    }

    @Test("a title format resolves the title it names")
    func titleFormats() {
        let payload = DeliveryPayloadTests.payload(title: "Board call", aiTitle: "Q3 budget")
        #expect(TitleFormat.title.title(for: payload) == "Board call")
        #expect(TitleFormat.aiTitle.title(for: payload) == "Q3 budget")
        #expect(
            TitleFormat.dateAndTitle.title(for: payload, timeZone: TimeZone(identifier: "UTC")!)
                == "2026-06-01 Board call"
        )
    }

    @Test("an AI title that was never written falls back to the entry's own")
    func aiTitleFallsBack() {
        let none = DeliveryPayloadTests.payload(title: "Board call", aiTitle: nil)
        #expect(TitleFormat.aiTitle.title(for: none) == "Board call")
        let blank = DeliveryPayloadTests.payload(title: "Board call", aiTitle: "   ")
        #expect(TitleFormat.aiTitle.title(for: blank) == "Board call")
    }
}
