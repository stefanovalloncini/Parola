import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Parola
import ParolaCore
import ParolaTestSupport

@MainActor
@Suite("Duplicate import sheet", .serialized)
struct DuplicateImportSheetTests {
    private static let pending = DuplicateImport(
        entryID: "board-meeting",
        entryTitle: "Board meeting",
        modelName: "openai_whisper-tiny",
        createdAt: Date(timeIntervalSince1970: 1_800_000_000),
        durationSeconds: 61,
        fileURL: URL(fileURLWithPath: "/tmp/Board meeting.m4a"),
        digest: "digest",
        translateOverride: nil
    )

    private func makeModel(_ label: String) -> AppModel {
        let model = AppModel(skipBootstrap: true, defaults: temporaryDefaults(), libraryURL: makeTempLibraryURL(label))
        model.duplicateImport = Self.pending
        return model
    }

    private func host(_ model: AppModel, locale: Locale = Locale(identifier: "en_US")) -> HostedWindow {
        let sheet = DuplicateImportSheet(pending: Self.pending)
            .environment(model)
            .environment(\.locale, locale)
        return HostedWindow(sheet, width: 500, height: 360)
    }

    private func element(_ leaf: String, in elements: [HostedAccessibility.Element]) throws -> HostedAccessibility.Element {
        let found = elements.first { $0.identifier?.hasSuffix(leaf) == true }
        return try #require(found, "no \(leaf)")
    }

    @Test("Cancel closes the sheet without choosing, even with Remember ticked")
    func cancelChoosesNothing() throws {
        let model = makeModel("duplicate-sheet-cancel")
        let hosted = host(model)
        defer { hosted.close() }
        let ticked = HostedAccessibility.press(endingWith: "Duplicate.Toggle.Remember", in: hosted.host)
        #expect(ticked)
        let pressed = HostedAccessibility.press(endingWith: "Duplicate.Button.Cancel", in: hosted.host)
        #expect(pressed)
        #expect(model.duplicateImport == nil)
        #expect(model.duplicateImportPolicy == .alwaysAsk)
        #expect(model.fileTranscribeTask == nil)
        #expect(model.selectedEntryID == nil)
    }

    @Test("⎋ is Cancel and ↩ is Open Existing")
    func keys() throws {
        let escaping = makeModel("duplicate-sheet-escape")
        let first = host(escaping)
        let firstTicked = HostedAccessibility.press(endingWith: "Duplicate.Toggle.Remember", in: first.host)
        #expect(firstTicked)
        let firstEscape = first.press(.escape)
        #expect(firstEscape)
        first.close()
        #expect(escaping.duplicateImport == nil)
        #expect(escaping.duplicateImportPolicy == .alwaysAsk)

        let returning = makeModel("duplicate-sheet-return")
        let second = host(returning)
        defer { second.close() }
        let secondTicked = HostedAccessibility.press(endingWith: "Duplicate.Toggle.Remember", in: second.host)
        #expect(secondTicked)
        let secondReturn = second.press(.return)
        #expect(secondReturn)
        #expect(returning.duplicateImport == nil)
        #expect(returning.duplicateImportPolicy == .openExisting)
    }

    @Test("the summary names the file right under the title, and VoiceOver reads it after the heading")
    func summaryUnderTheTitle() throws {
        let model = makeModel("duplicate-sheet-summary")
        let hosted = host(model)
        defer { hosted.close() }
        let elements = HostedAccessibility.elements(in: hosted.host)
        let title = try element("Sheet.Text.Title", in: elements)
        let summary = try element("Duplicate.Text.Summary", in: elements)
        #expect(title.name == "Already in your library")
        #expect(summary.words == ["Board meeting.m4a matches a transcript you already have."])
        #expect(summary.frame.maxY <= title.frame.minY)
        let titleIndex = elements.firstIndex { $0.identifier?.hasSuffix("Sheet.Text.Title") == true }
        let summaryIndex = elements.firstIndex { $0.identifier?.hasSuffix("Duplicate.Text.Summary") == true }
        let read = try #require(titleIndex)
        let next = try #require(summaryIndex)
        #expect(read < next)
    }

    @Test("Remember this choice sits above the buttons, and the footer reads Transcribe Again · Cancel · Open Existing")
    func footerOrder() throws {
        let model = makeModel("duplicate-sheet-footer")
        let hosted = host(model)
        defer { hosted.close() }
        let elements = HostedAccessibility.elements(in: hosted.host)
        let remember = try element("Duplicate.Toggle.Remember", in: elements).frame
        let again = try element("Duplicate.Button.TranscribeAgain", in: elements).frame
        let cancel = try element("Duplicate.Button.Cancel", in: elements).frame
        let open = try element("Duplicate.Button.OpenExisting", in: elements).frame
        #expect(remember.minY > cancel.maxY, "the checkbox shares the footer's row")
        #expect(again.maxX <= cancel.minX)
        #expect(cancel.maxX <= open.minX)
        #expect(open.minX - cancel.maxX < 24)
    }

    @Test("the footer's three buttons show whole", arguments: ["en_US", "it_IT"])
    func footerFits(_ identifier: String) throws {
        let locale = Locale(identifier: identifier)
        let model = makeModel("duplicate-sheet-fit")
        let hosted = host(model, locale: locale)
        defer { hosted.close() }
        let elements = HostedAccessibility.elements(in: hosted.host)
        let leadingEdge = hosted.window.frame.minX
        let buttons: [(leaf: String, title: LocalizedStringKey, primary: Bool)] = [
            ("Duplicate.Button.TranscribeAgain", "Transcribe Again", false),
            ("Duplicate.Button.Cancel", "Cancel", false),
            ("Duplicate.Button.OpenExisting", "Open Existing", true),
        ]
        for button in buttons {
            let frame = try element(button.leaf, in: elements).frame
            let whole = SheetButtonSize.natural(button.title, primary: button.primary, locale: locale)
            #expect(frame.width >= whole.width - 0.5, "\(button.leaf) is \(frame.width) pt of \(whole.width)")
            #expect(frame.minX >= leadingEdge, "\(button.leaf) starts past the sheet's leading edge")
        }
    }
}

/// What a footer button measures when nothing squeezes it.
@MainActor
enum SheetButtonSize {
    static func natural(_ title: LocalizedStringKey, primary: Bool, locale: Locale) -> CGSize {
        let button = Group {
            if primary {
                Button(title) {}.sheetPrimaryAction()
            } else {
                Button(title) {}.sheetSecondaryAction()
            }
        }
        .environment(\.locale, locale)
        return NSHostingView(rootView: button).fittingSize
    }
}
