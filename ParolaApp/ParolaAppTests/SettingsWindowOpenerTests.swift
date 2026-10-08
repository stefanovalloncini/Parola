import AppKit
import Testing
@testable import Parola

@MainActor
@Suite("Settings window opener")
struct SettingsWindowOpenerTests {
    @Test("opens Settings through the app menu's ⌘, item")
    func performsTheSettingsItem() {
        let target = MenuTarget()
        let menu = appMenu(target: target, settingsKey: ",", settingsModifiers: .command)

        SettingsWindowOpener.open(appMenu: menu)

        #expect(target.picked == ["Settings…"])
    }

    @Test("a menu with no ⌘, item opens nothing")
    func needsTheCommandComma() {
        let target = MenuTarget()
        let menu = appMenu(target: target, settingsKey: ",", settingsModifiers: [.command, .option])

        SettingsWindowOpener.open(appMenu: menu)

        #expect(target.picked.isEmpty)
    }

    private func appMenu(target: MenuTarget, settingsKey: String, settingsModifiers: NSEvent.ModifierFlags) -> NSMenu {
        let menu = NSMenu()
        for (title, key) in [("About Parola", ""), ("Settings…", settingsKey), ("Hide Parola", "h")] {
            let item = NSMenuItem(title: title, action: #selector(MenuTarget.pick(_:)), keyEquivalent: key)
            item.target = target
            if title == "Settings…" { item.keyEquivalentModifierMask = settingsModifiers }
            menu.addItem(item)
            if title == "About Parola" { menu.addItem(.separator()) }
        }
        return menu
    }

    private final class MenuTarget: NSObject {
        var picked: [String] = []

        @objc func pick(_ sender: NSMenuItem) {
            picked.append(sender.title)
        }
    }
}
