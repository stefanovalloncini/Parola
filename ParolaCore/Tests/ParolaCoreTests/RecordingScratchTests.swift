import Foundation
import Testing
@testable import ParolaCore

@Suite("RecordingScratch", .serialized)
struct RecordingScratchTests {

    @Test("defaults to the temp directory")
    func defaultsToTemp() {
        RecordingScratch.setDirectory(nil)
        let url = RecordingScratch.fileURL(prefix: "parola-test")
        #expect(url.path.hasPrefix(FileManager.default.temporaryDirectory.path))
        #expect(url.lastPathComponent.hasPrefix("parola-test-"))
        #expect(url.pathExtension == "wav")
    }

    @Test("an override redirects new files and creates the directory")
    func overrideRedirects() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("scratch-test-\(UUID().uuidString)", isDirectory: true)
        RecordingScratch.setDirectory(dir)
        defer {
            RecordingScratch.setDirectory(nil)
            try? FileManager.default.removeItem(at: dir)
        }
        let url = RecordingScratch.fileURL(prefix: "parola-mic")
        #expect(url.deletingLastPathComponent().path == dir.path)
        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDirectory))
        #expect(isDirectory.boolValue)
    }
}
