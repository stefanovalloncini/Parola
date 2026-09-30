import AppKit
import Foundation
import Testing
@testable import Parola
import ParolaCore
import ParolaTestSupport

@Suite("Pasted links")
struct PastedLinkTests {
    @Test("a pasted web address opens the link flow")
    func webAddress() {
        #expect(PastedLink.url(from: "https://youtu.be/abc123")?.host() == "youtu.be")
        #expect(PastedLink.url(from: "  https://example.com/talk.mp4\n")?.path() == "/talk.mp4")
    }

    @Test("words, files, other schemes and two links don't")
    func notALink() {
        #expect(PastedLink.url(from: "hello world") == nil)
        #expect(PastedLink.url(from: "file:///Users/me/a.m4a") == nil)
        #expect(PastedLink.url(from: "ftp://example.com/a") == nil)
        #expect(PastedLink.url(from: "https://a.com https://b.com") == nil)
        #expect(PastedLink.url(from: "") == nil)
    }

    private func withPasteboard(_ fill: (NSPasteboard) -> Void) -> URL? {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("PastedLinkTests-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        fill(pasteboard)
        return PastedLink.url(on: pasteboard)
    }

    @Test("a link copied from a browser arrives as a URL item")
    func urlItem() {
        let link = withPasteboard { $0.writeObjects([URL(string: "https://youtu.be/abc123")! as NSURL]) }
        #expect(link?.absoluteString == "https://youtu.be/abc123")
    }

    @Test("a link copied as text is read from the string")
    func linkAsText() {
        let link = withPasteboard { $0.setString(" https://vimeo.com/42\n", forType: .string) }
        #expect(link?.absoluteString == "https://vimeo.com/42")
    }

    @Test("a copied word or a copied file opens nothing")
    func notLinksOnThePasteboard() {
        #expect(withPasteboard { $0.setString("meeting notes", forType: .string) } == nil)
        #expect(withPasteboard { $0.writeObjects([URL(fileURLWithPath: "/tmp/a.m4a") as NSURL]) } == nil)
        #expect(withPasteboard { _ in } == nil)
    }
}

@MainActor
@Suite("The link sheet")
struct LinkSheetTests {
    private func makeModel(features: Set<ParolaFeature> = Set(ParolaFeature.allCases)) -> AppModel {
        AppModel(bootstrap: AppBootstrap(
            mode: .test,
            library: makeTempLibraryURL("linksheet"),
            defaultsOverride: temporaryDefaults(),
            sideEffects: [],
            filePicker: SystemFilePicker(),
            enabledFeaturesOverride: features
        ))
    }

    private let link = URL(string: "https://youtu.be/abc123")!

    @Test("a pasted link opens the sheet with the link filled in, once")
    func prefilledOnce() {
        let model = makeModel()

        model.openLinkSheet(prefill: link)

        #expect(model.youtubeSheetOpen)
        #expect(model.takeLinkSheetPrefill() == link)
        #expect(model.takeLinkSheetPrefill() == nil, "a later open must start empty")
    }

    @Test("opening the sheet without a link drops one left from before")
    func emptyOpenClearsAStalePrefill() {
        let model = makeModel()
        model.openLinkSheet(prefill: link)
        model.youtubeSheetOpen = false

        model.openLinkSheet(prefill: nil)

        #expect(model.youtubeSheetOpen)
        #expect(model.takeLinkSheetPrefill() == nil)
    }

    @Test("a build without links opens no link sheet")
    func gatedOff() {
        let model = makeModel(features: Set(ParolaFeature.allCases).subtracting([.youtube]))

        model.openLinkSheet(prefill: link)

        #expect(!model.youtubeSheetOpen)
        #expect(model.takeLinkSheetPrefill() == nil)
    }
}
