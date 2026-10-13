import Foundation
import Testing
@testable import ParolaCore

@Suite("Source app bundle ID")
struct SourceAppBundleIDTests {
    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    @Test("a manifest without the key decodes to nil and writes none back")
    func legacyAndOmitted() throws {
        let json = """
        {"version": 2, "createdAt": "2026-05-18T00:00:00Z", "originalAudioName": "x.wav",
         "modelName": "m", "language": "en", "category": "meeting", "source": "systemAudio"}
        """
        let manifest = try decoder.decode(ParolaDocument.Manifest.self, from: Data(json.utf8))
        #expect(manifest.sourceAppBundleID == nil)
        #expect(manifest.version == 2)
        let written = String(decoding: try encoder.encode(manifest), as: UTF8.self)
        #expect(!written.contains("sourceAppBundleID"))
    }

    @Test("a stored bundle ID round-trips")
    func roundTrip() throws {
        var manifest = ParolaDocument.Manifest(originalAudioName: "x.wav", modelName: "m", language: "en")
        manifest.sourceAppBundleID = "us.zoom.xos"
        let round = try decoder.decode(ParolaDocument.Manifest.self, from: try encoder.encode(manifest))
        #expect(round.sourceAppBundleID == "us.zoom.xos")
    }

    @Test("an entry added with a source app keeps it, and one added without has none")
    func addKeepsSourceApp() async throws {
        try await withStore { store in
            let transcript = Transcript(segments: [], language: "en", modelName: "tiny")
            let zoom = try await store.add(
                transcript: transcript, audioSource: nil, category: .meeting, sourceAppBundleID: "us.zoom.xos"
            )
            let plain = try await store.add(transcript: transcript, audioSource: nil)

            #expect(zoom.sourceAppBundleID == "us.zoom.xos")
            #expect(plain.sourceAppBundleID == nil)
            let listed = try await store.list()
            let reloaded = listed.first { $0.id == zoom.id }
            #expect(reloaded?.sourceAppBundleID == "us.zoom.xos")
        }
    }

    private func withStore(_ body: (LibraryStore) async throws -> Void) async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("parola-source-app-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try await body(LibraryStore(libraryURL: folder, extraIndexer: nil))
    }
}
