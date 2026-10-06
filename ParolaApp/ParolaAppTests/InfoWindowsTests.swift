import AppKit
import Foundation
import Testing
@testable import Parola

@MainActor
@Suite("About and Keyboard Shortcuts windows", .serialized)
struct InfoWindowsTests {
    private func menu(_ pick: @MainActor (NSMenu) -> NSMenu?) async -> NSMenu? {
        await waitUntil { NSApp.mainMenu.flatMap(pick) != nil }
        return NSApp.mainMenu.flatMap(pick)
    }

    private func visibleWindow(titled title: String) -> NSWindow? {
        NSApp.windows.first { $0.title == title && $0.isVisible }
    }

    /// Picks the item the way a click would, then waits for a window with that title.
    private func open(_ item: String, in menu: NSMenu, expecting title: String) async throws -> NSWindow {
        let index = try #require(menu.items.firstIndex { $0.title == item }, "no \(item) in \(menu.title)")
        menu.performActionForItem(at: index)
        await waitUntil(timeoutMs: 3_000) { visibleWindow(titled: title) != nil }
        return try #require(visibleWindow(titled: title))
    }

    @Test("About Parola opens a window of its own, not a sheet on the main window")
    func aboutIsAWindow() async throws {
        let appMenu = try #require(await menu { $0.items.first?.submenu })
        let window = try await open("About Parola", in: appMenu, expecting: String(localized: "About Parola"))
        defer { window.close() }
        #expect(window.sheetParent == nil)
    }

    @Test("Keyboard Shortcuts opens a window of its own, not a sheet on the main window")
    func shortcutsIsAWindow() async throws {
        let help = try #require(await menu { $0.items.first { $0.title == "Help" }?.submenu })
        let window = try await open("Keyboard Shortcuts…", in: help, expecting: String(localized: "Keyboard Shortcuts"))
        defer { window.close() }
        #expect(window.sheetParent == nil)
    }

    @Test("asking twice brings back the one window")
    func oneAboutWindow() async throws {
        let appMenu = try #require(await menu { $0.items.first?.submenu })
        let first = try await open("About Parola", in: appMenu, expecting: String(localized: "About Parola"))
        defer { first.close() }
        let second = try await open("About Parola", in: appMenu, expecting: String(localized: "About Parola"))
        #expect(first === second)
        #expect(NSApp.windows.filter { $0.title == String(localized: "About Parola") && $0.isVisible }.count == 1)
    }
}
