#if os(macOS)
import Foundation
import Testing
@testable import ParolaCore

/// yt-dlp's own file names: `<id>.<lang>.vtt`, and `<id>.<lang>-orig.vtt` for YouTube's speech recognition.
@Suite("YouTube caption tracks")
struct YouTubeCaptionTrackTests {
    private static let videoID = "dQw4w9WgXcQ"

    private static func phrase(_ index: Int) -> [String] {
        (0..<4).map { "w\(index)x\($0)" }
    }

    private static func stamp(_ seconds: Double) -> String {
        let millis = Int((seconds * 1000).rounded())
        return String(format: "00:%02d:%02d.%03d", millis / 60_000, (millis / 1000) % 60, millis % 1000)
    }

    /// The shape YouTube serves: a rolling cue (last line again, then the new line with inline word times) and a 10 ms cue that settles it.
    static func speechRecognitionVTT(phrases count: Int) -> String {
        var vtt = "WEBVTT\nKind: captions\nLanguage: en\n\n"
        for index in 0..<count {
            let start = Double(index) * 3
            let words = phrase(index)
            var timed = words[0]
            for (offset, word) in words.dropFirst().enumerated() {
                timed += "<\(stamp(start + 0.5 * Double(offset + 1)))><c> \(word)</c>"
            }
            let carried = index == 0 ? " " : phrase(index - 1).joined(separator: " ")
            vtt += "\(stamp(start)) --> \(stamp(start + 2.99)) align:start position:0%\n\(carried)\n\(timed)\n\n"
            vtt += "\(stamp(start + 2.99)) --> \(stamp(start + 3)) align:start position:0%\n\(words.joined(separator: " "))\n \n\n"
        }
        return vtt
    }

    static let handMadeVTT = """
        WEBVTT
        Kind: captions
        Language: en

        00:00:01.000 --> 00:00:03.000
        <c.colorE5E5E5>We said yes</c>

        00:00:03.000 --> 00:00:03.080
        Yes.

        00:00:03.080 --> 00:00:05.000
        yes we did

        """

    private func captionFolder(_ files: [String: String]) throws -> [URL] {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("parola-captions-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return try files.map { name, body in
            let url = folder.appendingPathComponent(name)
            try body.write(to: url, atomically: true, encoding: .utf8)
            return url
        }
    }

    private func wordCount(_ transcript: Transcript) -> Int {
        transcript.segments.reduce(0) { $0 + $1.text.split(separator: " ").count }
    }

    @Test("a speech-recognition track lands each phrase once")
    func speechRecognitionDedupes() throws {
        let raw = Self.speechRecognitionVTT(phrases: 150)
        let files = try captionFolder(["\(Self.videoID).en-orig.vtt": raw, "\(Self.videoID).en.vtt": raw])

        let transcript = try #require(try YouTubeSubsFetcher.captions(from: files, preferLanguage: nil))

        #expect(wordCount(VttImporter.parse(raw)) > 150 * 4 * 2)
        #expect(wordCount(transcript) == 150 * 4)
        #expect(transcript.text.contains("w149x3"))
        #expect(transcript.modelName == "youtube-auto-subs")
        #expect(transcript.language == "en")
    }

    @Test("a hand-made track in the spoken language wins and keeps every cue")
    func handMadeTrackUntouched() throws {
        let files = try captionFolder([
            "\(Self.videoID).en-orig.vtt": Self.speechRecognitionVTT(phrases: 5),
            "\(Self.videoID).en.vtt": Self.handMadeVTT,
        ])

        let transcript = try #require(try YouTubeSubsFetcher.captions(from: files, preferLanguage: nil))

        #expect(transcript.segments == VttImporter.parse(Self.handMadeVTT).segments)
        #expect(transcript.segments.map(\.text) == ["We said yes", "Yes.", "yes we did"])
        #expect(transcript.modelName == "youtube-subs")
    }

    @Test("on Auto an Italian video keeps its own words, not the English machine translation")
    func autoPicksTheOriginalLanguage() throws {
        let files = try captionFolder([
            "\(Self.videoID).it-orig.vtt": Self.speechRecognitionVTT(phrases: 3),
            "\(Self.videoID).en.vtt": Self.speechRecognitionVTT(phrases: 2),
        ])

        let transcript = try #require(try YouTubeSubsFetcher.captions(from: files, preferLanguage: nil))

        #expect(transcript.language == "it")
        #expect(wordCount(transcript) == 3 * 4)
    }

    @Test("a hand-made track in another language waits behind the original's speech recognition")
    func originalBeatsOtherLanguage() throws {
        let files = try captionFolder([
            "\(Self.videoID).it-orig.vtt": Self.speechRecognitionVTT(phrases: 3),
            "\(Self.videoID).en.vtt": Self.handMadeVTT,
        ])

        let transcript = try #require(try YouTubeSubsFetcher.captions(from: files, preferLanguage: nil))

        #expect(transcript.language == "it")
        #expect(transcript.modelName == "youtube-auto-subs")
    }

    @Test("with no speech recognition at all, a hand-made track is taken")
    func handMadeOnly() throws {
        let files = try captionFolder(["\(Self.videoID).en.vtt": Self.handMadeVTT])

        let transcript = try #require(try YouTubeSubsFetcher.captions(from: files, preferLanguage: nil))

        #expect(transcript.modelName == "youtube-subs")
        #expect(transcript.segments.count == 3)
    }

    @Test("word styling alone doesn't make a track look machine-made")
    func stylingIsNotSpeechRecognition() {
        let styled = """
            WEBVTT

            00:00:01.000 --> 00:00:02.000
            <00:00:01.200><c>karaoke</c> <00:00:01.600><c>line</c>
            """
        #expect(!CaptionTrack.looksLikeSpeechRecognition(styled))
        #expect(!CaptionTrack.looksLikeSpeechRecognition(Self.handMadeVTT))
        #expect(CaptionTrack.looksLikeSpeechRecognition(Self.speechRecognitionVTT(phrases: 2)))
    }

    @Test("Auto asks for the original track first; a set language asks for itself and its original")
    func requestedLanguages() {
        let url = URL(string: "https://www.youtube.com/watch?v=\(Self.videoID)")!
        let auto = YouTubeSubsFetcher.arguments(url: url, preferLanguage: nil, outputTemplate: "/tmp/x/%(id)s")
        let italian = YouTubeSubsFetcher.arguments(url: url, preferLanguage: "it", outputTemplate: "/tmp/x/%(id)s")

        #expect(auto.firstIndex(of: "--sub-langs").map { auto[$0 + 1] } == ".*-orig,en,en-US,en-GB")
        #expect(italian.firstIndex(of: "--sub-langs").map { italian[$0 + 1] } == "it,it-orig")
    }

    @Test("a fetch through yt-dlp's real file names returns the original track, deduped")
    func fetchThroughFakeYtDlp() async throws {
        let fixtures = try captionFolder([
            "asr.vtt": Self.speechRecognitionVTT(phrases: 20),
            "translated.vtt": Self.speechRecognitionVTT(phrases: 2),
        ])
        let asr = try #require(fixtures.first { $0.lastPathComponent == "asr.vtt" })
        let translated = try #require(fixtures.first { $0.lastPathComponent == "translated.vtt" })
        let requested = asr.deletingLastPathComponent().appendingPathComponent("requested.txt")
        let script = asr.deletingLastPathComponent().appendingPathComponent("yt-dlp")
        try """
            #!/bin/sh
            while [ $# -gt 0 ]; do
              case "$1" in
                -o) out="$2"; shift ;;
                --sub-langs) printf '%s' "$2" > '\(requested.path)'; shift ;;
              esac
              shift
            done
            base=$(printf '%s' "$out" | sed 's/%(id)s/\(Self.videoID)/')
            cp '\(asr.path)' "$base.it-orig.vtt"
            cp '\(translated.path)' "$base.en.vtt"
            echo '[PAROLA_META] {"title": "Una prova", "webpage_url": "https://www.youtube.com/watch?v=\(Self.videoID)", "id": "\(Self.videoID)"}'
            """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        let result = try await YouTubeSubsFetcher.fetchWithTitle(
            url: URL(string: "https://youtu.be/\(Self.videoID)")!, preferLanguage: nil, ytDlpPath: script.path
        )

        #expect(try String(contentsOf: requested, encoding: .utf8) == ".*-orig,en,en-US,en-GB")
        #expect(result.videoTitle == "Una prova")
        #expect(result.transcript.sourceURL == URL(string: "https://www.youtube.com/watch?v=\(Self.videoID)"))
        #expect(result.transcript.language == "it")
        #expect(result.transcript.modelName == "youtube-auto-subs")
        #expect(wordCount(result.transcript) == 20 * 4)
    }
}
#endif
