import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Parola
import ParolaCore
import ParolaTestSupport

/// Hands its text over only once something reads it, and counts the reads.
private final class CountingProvider: NSObject, NSPasteboardItemDataProvider {
    let text: String
    private(set) var reads = 0

    init(text: String) {
        self.text = text
    }

    func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
        reads += 1
        item.setString(text, forType: type)
    }
}

/// A window that reports itself key, since the test host never makes one key.
private final class KeyStubWindow: NSWindow {
    var reportsKey = true
    override var isKeyWindow: Bool { reportsKey }
}

@MainActor
@Suite("Link paste in the main window")
struct LinkPasteResponderTests {
    private let paste = #selector(NSText.paste(_:))

    private func chain(from window: NSWindow) -> [NSResponder] {
        var responders: [NSResponder] = []
        var responder = window.nextResponder
        while let current = responder {
            responders.append(current)
            responder = current.nextResponder
        }
        return responders
    }

    private func withPasteboard(_ body: (NSPasteboard) throws -> Void) rethrows {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("LinkPasteResponderTests-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        try body(pasteboard)
    }

    private func makeModel(features: Set<ParolaFeature> = Set(ParolaFeature.allCases), pasteboard: NSPasteboard) -> AppModel {
        let model = AppModel(bootstrap: AppBootstrap(
            mode: .test,
            library: makeTempLibraryURL("link-paste"),
            defaultsOverride: temporaryDefaults(),
            sideEffects: [],
            filePicker: SystemFilePicker(),
            enabledFeaturesOverride: features
        ))
        model.linkPasteboard = pasteboard
        return model
    }

    private func offers(_ model: AppModel, key: Bool = true, sheet: Bool = false) -> Bool {
        LinkPasteResponder.offersPaste(for: model, windowIsKey: key, windowHasSheet: sheet)
    }

    @Test("⌘V is offered for text or a URL while the window is up front and free")
    func offeredWhereTheLinkSheetCanOpen() {
        withPasteboard { pasteboard in
            pasteboard.setString("https://youtu.be/abc123", forType: .string)
            let model = makeModel(pasteboard: pasteboard)
            #expect(offers(model))
            #expect(!offers(model, key: false), "a panel or another window has the keyboard")
            #expect(!offers(model, sheet: true), "a sheet is already over the window")

            model.phase = .transcribing(file: URL(fileURLWithPath: "/tmp/a.m4a"))
            #expect(!offers(model), "New ▸ Transcribe Link… waits for the run too")
            model.phase = .failed(message: "The file couldn't be decoded.")
            #expect(offers(model))

            model.introduction.restart()
            #expect(!offers(model), "the introduction has no link sheet to show")
        }
    }

    @Test("⌘V stays on while a batch job runs, as New ▸ Transcribe Link… does")
    func offeredDuringABatchJob() {
        withPasteboard { pasteboard in
            pasteboard.setString("https://youtu.be/abc123", forType: .string)
            let model = makeModel(pasteboard: pasteboard)
            let file = URL(fileURLWithPath: "/tmp/LinkPasteResponderTests-batch.m4a")
            model.batchPhaseFile = file
            model.phase = .transcribing(file: file)

            #expect(model.batchOwnsPhase)
            #expect(offers(model))
        }
    }

    @Test("⌘V isn't offered for an image, an empty clipboard, or a build without links")
    func notOffered() {
        withPasteboard { pasteboard in
            let model = makeModel(pasteboard: pasteboard)
            #expect(!offers(model))
            pasteboard.setData(Data([0x89, 0x50, 0x4E, 0x47]), forType: .png)
            #expect(!offers(model))
        }
        withPasteboard { pasteboard in
            pasteboard.setString("https://youtu.be/abc123", forType: .string)
            let model = makeModel(features: Set(ParolaFeature.allCases).subtracting([.youtube]), pasteboard: pasteboard)
            #expect(!offers(model))
        }
    }

    @Test("the clipboard is judged by type while ⌘V is offered and read only once the paste happens")
    func contentsWaitForThePaste() {
        withPasteboard { pasteboard in
            let provider = CountingProvider(text: "https://youtu.be/abc123")
            let item = NSPasteboardItem()
            item.setDataProvider(provider, forTypes: [.string])
            pasteboard.writeObjects([item])
            let model = makeModel(pasteboard: pasteboard)
            let responder = LinkPasteResponder(model: model)

            #expect(offers(model))
            #expect(provider.reads == 0)

            responder.paste(nil)
            #expect(provider.reads > 0)
            #expect(model.youtubeSheetOpen)
            #expect(model.takeLinkSheetPrefill()?.absoluteString == "https://youtu.be/abc123")
        }
    }

    @Test("a pasted word or a page Parola can't fetch opens nothing")
    func onlyLinksOpenTheSheet() {
        for text in ["meeting notes", "https://example.com/talk.mp4"] {
            withPasteboard { pasteboard in
                pasteboard.setString(text, forType: .string)
                let model = makeModel(pasteboard: pasteboard)
                LinkPasteResponder(model: model).paste(nil)
                #expect(!model.youtubeSheetOpen, "\(text)")
            }
        }
    }

    private func hostWindow(_ root: some View) -> (NSWindow, NSWindowController) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1180, height: 760),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: true
        )
        window.isReleasedWhenClosed = false
        let controller = NSWindowController(window: window)
        window.contentViewController = NSHostingController(rootView: root)
        window.contentView?.layoutSubtreeIfNeeded()
        return (window, controller)
    }

    /// What the Paste menu item reaches from the window's first responder, the way AppKit walks it.
    private func pasteTarget(in window: NSWindow) -> NSResponder? {
        var responder = window.firstResponder
        while let current = responder {
            if current.responds(to: paste) { return current }
            responder = current.nextResponder
        }
        return nil
    }

    private func firstView<T: NSView>(_ type: T.Type, in view: NSView?) -> T? {
        guard let view else { return nil }
        if let match = view as? T { return match }
        return view.subviews.lazy.compactMap { firstView(type, in: $0) }.first
    }

    @Test("with nothing focused, or the sidebar list, ⌘V reaches the main window's link paste")
    func reachesTheWindowsLinkPaste() throws {
        try withPasteboard { pasteboard in
            pasteboard.setString("https://vimeo.com/42", forType: .string)
            let model = makeModel(pasteboard: pasteboard)
            let (window, controller) = hostWindow(ContentView().environment(model))
            defer { withExtendedLifetime(controller) { window.close() } }

            let responder = try #require(window.nextResponder as? LinkPasteResponder, "it sits right after the window")
            #expect(responder.nextResponder === controller, "and the window controller still follows")

            window.makeFirstResponder(nil)
            #expect(pasteTarget(in: window) === responder)

            let sidebar = try #require(firstView(NSTableView.self, in: window.contentView))
            let sidebarFocused = window.makeFirstResponder(sidebar)
            #expect(sidebarFocused)
            #expect(pasteTarget(in: window) === responder)

            let pasted = sidebar.tryToPerform(paste, with: nil)
            #expect(pasted)
            #expect(model.youtubeSheetOpen)
            #expect(model.takeLinkSheetPrefill()?.absoluteString == "https://vimeo.com/42")
        }
    }

    @Test("a focused text field keeps its own paste")
    func textFieldsPasteAsText() throws {
        try withPasteboard { pasteboard in
            let model = makeModel(pasteboard: pasteboard)
            let root = TextField(text: .constant("")) { Text(verbatim: "Title") }
                .background(LinkPasteInstaller(model: model))
            let (window, controller) = hostWindow(root)
            defer { withExtendedLifetime(controller) { window.close() } }

            let field = try #require(firstView(NSTextField.self, in: window.contentView))
            let fieldFocused = window.makeFirstResponder(field)
            #expect(fieldFocused)
            #expect(pasteTarget(in: window) is NSText)
        }
    }

    @Test("the app's own main window, the one its window group opens, carries the link paste")
    func appMainWindowCarriesIt() async throws {
        let opened = await waitUntil { AppDelegate.launchModel?.mainWindow != nil }
        #expect(opened)
        let window = try #require(AppDelegate.launchModel?.mainWindow)
        let spliced = await waitUntil { chain(from: window).contains { $0 is LinkPasteResponder } }
        #expect(spliced, "\(chain(from: window).map { String(describing: type(of: $0)) })")
    }

    @Test("becoming key puts the link paste back after something else takes the window's next responder")
    func repairsOnBecomingKey() async throws {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("LinkPasteResponderTests-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        let model = makeModel(pasteboard: pasteboard)
        let (window, controller) = hostWindow(Color.clear.background(LinkPasteInstaller(model: model)))
        defer { withExtendedLifetime(controller) { window.close() } }
        let responder = try #require(window.nextResponder as? LinkPasteResponder)

        window.nextResponder = controller
        #expect(!chain(from: window).contains(responder))
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
        let repaired = await waitUntil { window.nextResponder === responder }
        #expect(repaired)
        #expect(responder.nextResponder === controller)

        let replacement = NSWindowController(window: window)
        defer { withExtendedLifetime(replacement) {} }
        #expect(window.nextResponder === replacement, "a new window controller takes the slot")
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
        let repairedAgain = await waitUntil { window.nextResponder === responder }
        #expect(repairedAgain)
        #expect(responder.nextResponder === replacement)
    }

    @Test("⌘V stands down through a count-in, as it does through the take")
    func notDuringACountIn() {
        withPasteboard { pasteboard in
            pasteboard.setString("https://youtu.be/abc123", forType: .string)
            let model = makeModel(pasteboard: pasteboard)
            model.recordingCountInSeconds = 3
            model.startRecording(source: .microphone)
            #expect(model.recordingCountdown != nil)
            #expect(!offers(model), "the count-in is the take's first arming")

            model.cancelRecordingCountdown()
            #expect(!model.recordingActive)
            #expect(offers(model))
        }
    }

    @Test("the Paste item asks the window it sits in: key, no sheet over it, and only for Paste")
    func validatesThroughItsWindow() async throws {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("LinkPasteResponderTests-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setString("https://youtu.be/abc123", forType: .string)
        let model = makeModel(pasteboard: pasteboard)
        let window = KeyStubWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        let controller = NSWindowController(window: window)
        window.contentViewController = NSHostingController(rootView: Color.clear.background(LinkPasteInstaller(model: model)))
        window.contentView?.layoutSubtreeIfNeeded()
        defer { withExtendedLifetime(controller) { window.close() } }
        let responder = try #require(window.nextResponder as? LinkPasteResponder)
        let pasteItem = NSMenuItem(title: "Paste", action: paste, keyEquivalent: "v")
        let copyItem = NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")

        #expect(responder.validateUserInterfaceItem(pasteItem))
        #expect(!responder.validateUserInterfaceItem(copyItem))

        window.reportsKey = false
        #expect(!responder.validateUserInterfaceItem(pasteItem), "another window has the keyboard")
        window.reportsKey = true

        let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled], backing: .buffered, defer: true)
        window.beginSheet(sheet, completionHandler: nil)
        let sheetUp = await waitUntil { window.attachedSheet != nil }
        #expect(sheetUp)
        #expect(!responder.validateUserInterfaceItem(pasteItem), "a sheet is over the window")
        window.endSheet(sheet)
        let sheetGone = await waitUntil { window.attachedSheet == nil }
        #expect(sheetGone)
        #expect(responder.validateUserInterfaceItem(pasteItem))
    }

    @Test("the link paste leaves the window's chain with the content that put it there")
    func leavesWithTheContent() {
        withPasteboard { pasteboard in
            let model = makeModel(pasteboard: pasteboard)
            let (window, controller) = hostWindow(Color.clear.background(LinkPasteInstaller(model: model)))
            #expect(window.nextResponder is LinkPasteResponder)

            window.contentViewController = nil
            #expect(window.nextResponder === controller)
            window.close()
        }
    }
}
