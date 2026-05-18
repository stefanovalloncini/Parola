import Foundation
import Testing
@testable import ParolaCore

@Suite("HTML export theme")
struct HtmlThemeTests {
    private func transcript() -> Transcript {
        Transcript(
            schemaVersion: 1,
            segments: [TranscriptSegment(id: 1, start: 0, end: 2, text: "hi", speaker: "Alice")],
            language: "en",
            modelName: "x"
        )
    }

    @Test("light theme uses a white background")
    func light() throws {
        let exporter = HtmlExporter(options: HtmlOptions(theme: .light))
        let html = try String(data: exporter.render(transcript()), encoding: .utf8) ?? ""
        #expect(html.contains("background:#ffffff"))
        #expect(html.contains("color:#111111"))
    }

    @Test("dark theme uses a dark background")
    func dark() throws {
        let exporter = HtmlExporter(options: HtmlOptions(theme: .dark))
        let html = try String(data: exporter.render(transcript()), encoding: .utf8) ?? ""
        #expect(html.contains("background:#111111"))
        #expect(html.contains("color:#eeeeee"))
    }

    @Test("sepia theme uses a warm background")
    func sepia() throws {
        let exporter = HtmlExporter(options: HtmlOptions(theme: .sepia))
        let html = try String(data: exporter.render(transcript()), encoding: .utf8) ?? ""
        #expect(html.contains("background:#f4ecd8"))
    }

    @Test("default theme matches the historical light look")
    func defaultLight() throws {
        let exporter = HtmlExporter()
        let html = try String(data: exporter.render(transcript()), encoding: .utf8) ?? ""
        #expect(html.contains("background:#ffffff"))
    }
}
