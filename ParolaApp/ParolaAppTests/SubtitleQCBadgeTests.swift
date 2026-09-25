import Foundation
import Testing
import ParolaCore
@testable import Parola
import ParolaTestSupport

@MainActor
@Suite("Subtitle QC badges")
struct SubtitleQCBadgeTests {
    private func makeModel(_ defaults: UserDefaults) -> AppModel {
        AppModel(skipBootstrap: true, defaults: defaults, libraryURL: makeTempLibraryURL("subtitleqc"))
    }

    @Test("help text names each tripped rule on its own line")
    func helpTextCopy() {
        let text = SegmentCard.qcHelpText([
            .lineTooLong(limit: 42),
            .tooFast(charactersPerSecond: 27),
            .tooShort,
        ])
        #expect(text == "Line longer than 42 characters\n27 characters per second\nShorter than 0.7 seconds")
    }

    @Test("QC map flags only offending segments")
    func qcMapFlagsOffenders() {
        let segments = [
            TranscriptSegment(id: 0, start: 0, end: 2, text: "A calm and easy line."),
            TranscriptSegment(id: 1, start: 2, end: 2.4, text: "Rushed."),
        ]
        let map = SegmentsScroll.subtitleQCIssues(segments: segments, captionLength: .medium)
        #expect(map[0] == nil)
        #expect(map[1] == [.tooShort])
    }

    @Test("QC map honors the selected caption length")
    func qcMapUsesCaptionLength() {
        let word40 = String(repeating: "a", count: 40)
        let segments = [TranscriptSegment(id: 0, start: 0, end: 4, text: word40)]

        let short = SegmentsScroll.subtitleQCIssues(segments: segments, captionLength: .short)
        #expect(short[0] == [.lineTooLong(limit: 32)])

        let long = SegmentsScroll.subtitleQCIssues(segments: segments, captionLength: .long)
        #expect(long[0] == nil)
    }

    @Test("showSubtitleQC defaults to off, persists, and reloads")
    func persistsAndReloads() {
        let defaults = temporaryDefaults()
        let first = makeModel(defaults)
        #expect(first.showSubtitleQC == false)

        first.showSubtitleQC = true
        #expect(defaults.bool(forKey: "showSubtitleQC"))

        let second = makeModel(defaults)
        #expect(second.showSubtitleQC)

        defaults.set(false, forKey: "showSubtitleQC")
        second.reloadSettings()
        #expect(second.showSubtitleQC == false)
    }

    @Test("no pane's reset clears the inspector's checkbox, but a backup and a full reset still cover it")
    func keyIsUnscoped() {
        let scoped = Set(SettingsPaneScope.allCases.flatMap(\.defaultsKeys))
        #expect(scoped.contains("showSubtitleQC") == false)
        #expect(UnscopedSettingsKeys.all.contains("showSubtitleQC"))
    }
}
