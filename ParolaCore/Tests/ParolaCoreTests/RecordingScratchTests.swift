import Foundation
import Testing
import ParolaTestSupport
@testable import ParolaCore

// .logFacade: CaptureLoggingTests redirects the same process-wide scratch directory under that gate.
@Suite("RecordingScratch", .serialized, .logFacade)
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

    @Test("a meeting's microphone track is named after its take, beside it, and is never a take of its own")
    func meetingMicPairsWithItsTake() {
        let folder = URL(fileURLWithPath: "/tmp/parola-inflight", isDirectory: true)
        let take = folder.appendingPathComponent("parola-system-1234.wav")

        let mic = RecordingScratch.meetingMicURL(for: take)

        #expect(mic.lastPathComponent == "parola-meetmic-1234.wav")
        #expect(mic.deletingLastPathComponent().path == folder.path)
        #expect(RecordingScratch.isMeetingMic(mic))
        #expect(!RecordingScratch.isTake(mic), "a sweep must never import it as a take")
        #expect(RecordingScratch.takeNames(pairedWith: mic).contains(take.lastPathComponent))
        #expect(RecordingScratch.takeNames(pairedWith: take).isEmpty)
    }

    @Test("a take with no take name, like a fixture, gets a microphone track with a fresh name in the scratch folder")
    func fixtureTakeGetsAFreshMicName() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("scratch-test-\(UUID().uuidString)", isDirectory: true)
        RecordingScratch.setDirectory(dir)
        defer {
            RecordingScratch.setDirectory(nil)
            try? FileManager.default.removeItem(at: dir)
        }

        let mic = RecordingScratch.meetingMicURL(for: URL(fileURLWithPath: "/tmp/fixtures/meeting.wav"))

        #expect(mic.deletingLastPathComponent().path == dir.path)
        #expect(mic.lastPathComponent.hasPrefix("parola-meetmic-"))
        #expect(RecordingScratch.isMeetingMic(mic))
        #expect(RecordingScratch.meetingMicURL(for: nil).lastPathComponent != mic.lastPathComponent)
    }
}
