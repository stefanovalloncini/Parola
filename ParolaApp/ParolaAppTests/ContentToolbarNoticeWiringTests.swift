import Foundation
import Testing
@testable import Parola

/// `ContentToolbar` can't be rendered in a unit test, so this pins the source wiring instead:
/// `englishOnlyAutoNotice` must reach both the disabled language pill's tooltip and the options
/// popover, not just Settings — that's the visible half of R1.6 the review found missing.
@Suite("ContentToolbar English-only notice wiring")
struct ContentToolbarNoticeWiringTests {
    private func appSource(_ name: String) throws -> String {
        let path = #filePath.replacingOccurrences(
            of: "ParolaAppTests/ContentToolbarNoticeWiringTests.swift",
            with: "ParolaApp/\(name).swift"
        )
        let source = try String(contentsOfFile: path, encoding: .utf8)
        return source.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    @Test("the language pill's tooltip is fed from englishOnlyAutoNotice, not a static string")
    func tooltipUsesTheNotice() throws {
        let toolbar = try appSource("Views/ContentToolbar")
        #expect(toolbar.contains(
            #".modifier(LanguageNoticeHelpModifier(notice: languageControlNotice))"#
        ))
        #expect(toolbar.contains(
            #"private var languageControlNotice: String? { model.englishOnlyAutoNotice ?? model.languageMismatchWarning }"#
        ))
    }

    @Test("the options popover renders englishOnlyAutoNotice when it's set")
    func popoverRendersTheNotice() throws {
        let toolbar = try appSource("Views/ContentToolbar")
        #expect(toolbar.contains(
            #"if let notice = model.englishOnlyAutoNotice { Label(notice, systemImage: "exclamationmark.triangle.fill")"#
        ))
    }
}
