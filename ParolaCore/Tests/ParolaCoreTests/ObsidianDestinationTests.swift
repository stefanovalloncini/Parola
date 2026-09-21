import Foundation
import Testing
@testable import ParolaCore

@Suite("Obsidian vault folder destination", .tags(.fileSystem))
struct ObsidianDestinationTests {

    private func makeVault() throws -> URL {
        let vault = FileManager.default.temporaryDirectory
            .appendingPathComponent("parola-obsidian-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: vault.appendingPathComponent(".obsidian", isDirectory: true),
            withIntermediateDirectories: true
        )
        return vault
    }

    private func destination(
        vault: URL,
        subfolder: String = "",
        template: String = "{title}",
        collision: ObsidianCollisionPolicy = .appendCounter
    ) throws -> ObsidianVaultFolderDestination {
        ObsidianVaultFolderDestination(
            name: "Throwaway vault",
            categories: Set(EntryCategory.allCases),
            vaultBookmark: try ObsidianVaultFolderDestination.bookmark(for: vault),
            vaultPath: vault.path,
            subfolder: subfolder,
            filenameTemplate: template,
            collision: collision
        )
    }

    @Test("a delivery writes the note and reports where it landed")
    func writesTheNote() async throws {
        let vault = try makeVault()
        defer { try? FileManager.default.removeItem(at: vault) }
        let destination = try destination(vault: vault, subfolder: "Transcripts")

        let receipt = try await destination.deliver(ObsidianNoteRendererTests.payload())

        let expected = vault.appendingPathComponent("Transcripts/Interview.md")
        // A bookmark resolves to the canonical path, so /var and /private/var only match resolved.
        #expect(receipt.location?.resolvingSymlinksInPath() == expected.resolvingSymlinksInPath())
        #expect(receipt.destinationID == destination.id)
        #expect(receipt.destinationName == "Throwaway vault")
        let note = try String(contentsOf: expected, encoding: .utf8)
        #expect(note.hasPrefix("---\ntitle: \"Interview\""))
        #expect(note.contains("## Transcript"))
    }

    @Test("the counter policy never overwrites a note that is already there")
    func appendsACounter() async throws {
        let vault = try makeVault()
        defer { try? FileManager.default.removeItem(at: vault) }
        let destination = try destination(vault: vault)

        let first = try await destination.deliver(ObsidianNoteRendererTests.payload())
        let second = try await destination.deliver(ObsidianNoteRendererTests.payload())
        let third = try await destination.deliver(ObsidianNoteRendererTests.payload())

        #expect(first.location?.lastPathComponent == "Interview.md")
        #expect(second.location?.lastPathComponent == "Interview 2.md")
        #expect(third.location?.lastPathComponent == "Interview 3.md")
    }

    @Test("the overwrite policy writes the same file again")
    func overwrites() async throws {
        let vault = try makeVault()
        defer { try? FileManager.default.removeItem(at: vault) }
        let destination = try destination(vault: vault, collision: .overwrite)

        _ = try await destination.deliver(ObsidianNoteRendererTests.payload())
        let second = try await destination.deliver(ObsidianNoteRendererTests.payload())

        #expect(second.location?.lastPathComponent == "Interview.md")
        let names = try FileManager.default.contentsOfDirectory(atPath: vault.path).sorted()
        #expect(names == [".obsidian", "Interview.md"])
    }

    @Test("the title format names the note")
    func titleFormatNamesTheNote() async throws {
        let vault = try makeVault()
        defer { try? FileManager.default.removeItem(at: vault) }
        var destination = try destination(vault: vault)
        destination.titleFormat = .aiTitle

        let receipt = try await destination.deliver(ObsidianNoteRendererTests.payload())

        #expect(receipt.location?.lastPathComponent == "Release chat.md")
    }

    @Test("a subfolder cannot climb out of the vault")
    func subfolderIsConfined() async throws {
        let vault = try makeVault()
        defer { try? FileManager.default.removeItem(at: vault) }
        let destination = try destination(vault: vault, subfolder: "/../../escape/notes/")

        let receipt = try await destination.deliver(ObsidianNoteRendererTests.payload())

        let landed = try #require(receipt.location)
        #expect(landed.resolvingSymlinksInPath().path.hasPrefix(vault.resolvingSymlinksInPath().path))
        #expect(landed.path.hasSuffix("escape/notes/Interview.md"))
    }

    @Test("a vault that has gone misses reports itself")
    func missingVault() async throws {
        let vault = try makeVault()
        let destination = try destination(vault: vault)
        try FileManager.default.removeItem(at: vault)

        await #expect(throws: DeliveryError.self) {
            _ = try await destination.deliver(ObsidianNoteRendererTests.payload())
        }
    }

    @Test("the Obsidian URL points at the note that was written")
    func obsidianURL() {
        let url = ObsidianVaultFolderDestination.openInObsidianURL(
            for: URL(fileURLWithPath: "/tmp/parola-t29/obsidian-vault/Notes/Board call.md")
        )
        #expect(
            url?.absoluteString
                == "obsidian://open?path=/tmp/parola-t29/obsidian-vault/Notes/Board%20call.md"
        )
    }

    @Test("a destination only takes the categories it was given")
    func categoryFilter() throws {
        let vault = try makeVault()
        defer { try? FileManager.default.removeItem(at: vault) }
        var destination = try destination(vault: vault)
        destination.categories = [.meeting]
        #expect(destination.accepts(.meeting))
        #expect(!destination.accepts(.dictation))
    }
}
