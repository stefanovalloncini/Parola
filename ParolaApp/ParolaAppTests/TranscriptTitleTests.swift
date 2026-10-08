import AppKit
import Foundation
import SwiftUI
import Testing
import ParolaCore
@testable import Parola
import ParolaTestSupport

@MainActor
@Suite("Transcript title", .serialized)
struct TranscriptTitleTests {
    private static let heading = "Transcript.Heading.Title"
    private static let title = "Weekly product sync"

    private func withIsolatedDefaults(_ body: (UserDefaults) async throws -> Void) async rethrows {
        let previous = DefaultsStore.current
        let suite = temporaryDefaults("test-transcript-title-")
        DefaultsStore.current = suite
        defer { DefaultsStore.current = previous }
        try await body(suite)
    }

    private func makeModel(_ defaults: UserDefaults, segments: [TranscriptSegment]? = nil) -> AppModel {
        let model = AppModel(skipBootstrap: true, defaults: defaults, libraryURL: makeTempLibraryURL("transcript-title"))
        model.libraryLoaded = true
        model.transcript = Transcript(
            segments: segments ?? [
                TranscriptSegment(id: 0, start: 0, end: 4, text: "first we look at the launch", speaker: "Ada"),
                TranscriptSegment(id: 1, start: 4, end: 9, text: "then the budget for next quarter", speaker: "Bo"),
            ],
            language: "en",
            modelName: "stub",
            durationSeconds: 38 * 60
        )
        model.sourceFileURL = URL(fileURLWithPath: "/tmp/\(Self.title).m4a")
        model.phase = .ready
        return model
    }

    private func headingElement(in root: NSObject) -> HostedAccessibility.Element? {
        HostedAccessibility.elements(in: root).first { $0.identifier?.hasSuffix(Self.heading) == true }
    }

    private func italianBundle() throws -> Bundle {
        let path = try #require(Bundle.main.path(forResource: "it", ofType: "lproj"))
        return try #require(Bundle(path: path))
    }

    @Test("the meta line reads when, how long, how many voices and which language")
    func metaLineReadsInOrder() throws {
        let date = Date(timeIntervalSince1970: 1_790_000_000)
        let english = try #require(LanguageDisplay.name(for: "en"))
        let full = TranscriptMeta.line(createdAt: date, seconds: 38 * 60, speakers: 3, language: "en")
        #expect(full == "\(AppFormat.dateAndTime(date)) · 38 min · 3 speakers · \(english)")
        #expect(TranscriptMeta.line(createdAt: nil, seconds: 38 * 60, speakers: 1, language: "en") == "38 min · \(english)")
        #expect(TranscriptMeta.line(createdAt: nil, seconds: nil, speakers: 2, language: "unknown") == "2 speakers")
        #expect(TranscriptMeta.line(createdAt: nil, seconds: nil, speakers: 0, language: nil).isEmpty)
        let italian = TranscriptMeta.line(createdAt: nil, seconds: nil, speakers: 4, language: nil, bundle: try italianBundle())
        #expect(italian == "4 speaker")
    }

    @Test(
        "the name heads the text as a heading and scrolls away with it, in Paragraphs and in Segments",
        arguments: TranscriptDisplayMode.allCases
    )
    func nameHeadsTheText(layout: TranscriptDisplayMode) async {
        await withIsolatedDefaults { defaults in
            let model = makeModel(defaults)
            model.transcriptDisplayMode = layout
            let hosted = HostedWindow(ContentView().environment(model), width: 1180, height: 760)
            defer { hosted.close() }
            let drawn = await waitUntil { headingElement(in: hosted.host) != nil }
            #expect(drawn)
            let heading = headingElement(in: hosted.host)
            #expect(heading?.label?.contains(Self.title) == true, "reads \(heading?.label ?? "nothing")")
            #expect(heading?.label?.contains("38 min") == true)
            #expect(heading?.role == "AXHeading")
            #expect(heading?.actions.contains("Rename…") == true)

            let scrolls = HostedAccessibility.elements(in: hosted.host).filter { $0.role == NSAccessibility.Role.scrollArea.rawValue }
            let holder = scrolls.first { scroll in
                let inside = HostedAccessibility.elements(in: scroll.object)
                let hasHeading = inside.contains { $0.identifier?.hasSuffix(Self.heading) == true }
                let hasText = inside.flatMap(\.words).contains { $0.contains("first we look at the launch") }
                return hasHeading && hasText
            }
            #expect(holder != nil, "the heading isn't in the scroll that holds the text")
        }
    }

    @Test("a transcript with no words still shows its name")
    func emptyTranscriptKeepsItsName() async {
        await withIsolatedDefaults { defaults in
            let model = makeModel(defaults, segments: [TranscriptSegment(id: 0, start: 0, end: 2, text: " ")])
            #expect(model.transcriptIsEmpty)
            let hosted = HostedWindow(ContentView().environment(model), width: 1180, height: 760)
            defer { hosted.close() }
            let drawn = await waitUntil { headingElement(in: hosted.host) != nil }
            #expect(drawn)
            #expect(headingElement(in: hosted.host)?.label?.contains(Self.title) == true)
        }
    }

    @Test("the heading's Rename… asks for the same rename the Transcript menu does")
    func headingRenameUsesTheMenusRequest() async throws {
        try await withIsolatedDefaults { defaults in
            let model = makeModel(defaults)
            model.selectedEntryID = "entry"
            #expect(model.canRenameOpenTranscript)
            let hosted = HostedWindow(TranscriptTitleHeading().environment(model), width: 600, height: 200)
            defer { hosted.close() }
            let element = try #require(headingElement(in: hosted.host))
            let actions = element.object.value(forKey: "accessibilityCustomActions") as? [NSAccessibilityCustomAction] ?? []
            let offered = actions.first { $0.name == "Rename…" }
            let rename = try #require(offered)
            let before = model.renameRequests
            if let handler = rename.handler {
                _ = handler()
            } else if let target = rename.target as? NSObject, let selector = rename.selector {
                _ = target.perform(selector, with: rename)
            }
            #expect(model.renameRequests == before &+ 1)
        }
    }

    @Test("Show Outline and Jump to Time… open their popovers with no header bar to hang them from")
    func menuRequestsOpenThePopovers() async {
        await withIsolatedDefaults { defaults in
            let model = makeModel(defaults)
            let hosted = HostedWindow(ContentView().environment(model), width: 1180, height: 760)
            defer {
                hosted.close()
                closePopovers(except: hosted.window)
            }
            let drawn = await waitUntil { headingElement(in: hosted.host) != nil }
            #expect(drawn)

            model.outlineRequests &+= 1
            let outline = await waitUntil { popoverWords(except: hosted.window).contains("Outline") }
            #expect(outline)
            closePopovers(except: hosted.window)

            model.jumpToTimeRequests &+= 1
            let jump = await waitUntil { popoverIDs(except: hosted.window).contains { $0.hasSuffix("JumpToTime.TextField.Time") } }
            #expect(jump)
        }
    }

    private func popovers(except window: NSWindow) -> [NSWindow] {
        NSApp.windows.filter { $0 !== window && $0.isVisible && String(describing: type(of: $0)).contains("Popover") }
    }

    private func popoverWords(except window: NSWindow) -> [String] {
        popovers(except: window).flatMap { HostedAccessibility.words(in: $0) }
    }

    private func popoverIDs(except window: NSWindow) -> [String] {
        popovers(except: window).flatMap { HostedAccessibility.elements(in: $0).compactMap(\.identifier) }
    }

    private func closePopovers(except window: NSWindow) {
        popovers(except: window).forEach { $0.orderOut(nil) }
    }
}
