import CoreGraphics
import Foundation
import Testing
@testable import ParolaCore

@Suite("Caption cue speed")
struct CaptionPerformanceTests {
    private static let english = "So the thing about building a transcription app is that every part of it looks simple until you try to make it work for a two hour meeting recorded on a laptop in a noisy café, and then the captions have to fit on a phone screen."
    private static let japanese = "今日は新しい字幕の分割について説明します。長い文章は読みやすい長さに切り、話している間だけ画面に表示されます。キャッシュを消してちょっと待ってください。"

    private func transcript(_ text: String, segments: Int, language: String) -> Transcript {
        Transcript(
            segments: (0..<segments).map { TranscriptSegment(id: $0, start: Double($0) * 12, end: Double($0) * 12 + 11, text: text) },
            language: language, modelName: "test"
        )
    }

    private func seconds(_ body: () throws -> Void) rethrows -> Double {
        let started = Date()
        try body()
        return Date().timeIntervalSince(started)
    }

    @Test("five thousand English segments split in a few seconds even unoptimised")
    func englishExport() throws {
        let transcript = transcript(Self.english, segments: 5000, language: "en")
        let exporter = SrtExporter(spec: .srt(captionLength: .medium))
        let took = try seconds { _ = try exporter.render(transcript) }
        print("caption speed: 5k English segments, medium: \(took) s")
        #expect(took < 30)
    }

    @Test("five thousand Japanese segments split in a few seconds even unoptimised")
    func japaneseExport() throws {
        let transcript = transcript(Self.japanese, segments: 5000, language: "ja")
        let exporter = SrtExporter(spec: .srt(captionLength: .medium))
        let took = try seconds { _ = try exporter.render(transcript) }
        print("caption speed: 5k Japanese segments, medium: \(took) s")
        #expect(took < 30)
    }

    @Test("checking two hundred Japanese segments for QC is quick")
    func japaneseQC() {
        let segments = transcript(Self.japanese, segments: 200, language: "ja").segments
        let cold = seconds { _ = SubtitleQC.issues(forSegments: segments, captionLength: .medium) }
        let warm = seconds { _ = SubtitleQC.issues(forSegments: segments, captionLength: .medium) }
        print("caption speed: QC of 200 Japanese segments: first \(cold) s, again \(warm) s")
        #expect(warm < 5)
    }

    private func burnSeconds(_ transcript: Transcript) throws -> Double {
        var options = ExportSpec.srt(captionLength: .medium).options
        options.captionLength = .medium
        let size = CGSize(width: 1920, height: 1080)
        let metrics = SubtitleBurner.CaptionMetrics(style: SubtitleBurner.Style(), renderSize: size)
        return try seconds { _ = try SubtitleBurner.cues(from: transcript, options: options, metrics: metrics, renderSize: size) }
    }

    @Test("burn cues for five thousand English segments are built in a few seconds even unoptimised")
    func englishBurn() throws {
        let took = try burnSeconds(transcript(Self.english, segments: 5000, language: "en"))
        print("caption speed: burn cues, 5k English segments, medium: \(took) s")
        #expect(took < 60)
    }

    @Test("burn cues for a thousand Japanese segments are built in a few seconds even unoptimised")
    func japaneseBurn() throws {
        let took = try burnSeconds(transcript(Self.japanese, segments: 1000, language: "ja"))
        print("caption speed: burn cues, 1k Japanese segments, medium: \(took) s")
        #expect(took < 60)
    }
}
