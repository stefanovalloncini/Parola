import Foundation
import Testing
@testable import Parola
import ParolaCore

@Suite("Batch media kind")
struct BatchMediaKindTests {

    private static func kind(_ ext: String) -> BatchMediaKind {
        BatchMediaKind(url: URL(fileURLWithPath: "/tmp/BatchMediaKindTests/take.\(ext)"))
    }

    @Test("every audio extension intake accepts reads as audio")
    func audioExtensions() {
        for ext in FolderWatcher.audioExtensions {
            #expect(Self.kind(ext) == .audio, "\(ext) should be audio")
            #expect(Self.kind(ext.uppercased()) == .audio, "\(ext) uppercased should be audio")
        }
    }

    @Test("every video extension intake accepts reads as video")
    func videoExtensions() {
        #expect(FolderWatcher.videoExtensions.contains("mkv"))
        for ext in FolderWatcher.videoExtensions {
            #expect(Self.kind(ext) == .video, "\(ext) should be video")
            #expect(Self.kind(ext.uppercased()) == .video, "\(ext) uppercased should be video")
        }
    }

    @Test("an extension neither list knows falls back to the declared type")
    func unknownExtensions() {
        #expect(Self.kind("mpg") == .video)
        #expect(Self.kind("mp2") == .audio)
        #expect(Self.kind("zzz") == .audio)
        #expect(Self.kind("") == .audio)
    }
}
