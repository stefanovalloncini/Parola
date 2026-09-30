import Foundation
import AppKit
import ParolaCore

/// True only for the SwiftUI `Settings` scene window. The main `WindowGroup` window has a
/// `com.apple.SwiftUI.Window`-style identifier and can become the main window; Settings carries a
/// `com.apple.SwiftUI.Settings` identifier (titled "<App> Settings"). Width is not a reliable
/// discriminator — the panes can be wider than the default main window — so we never key off it,
/// and we hard-guard against ever matching the main/key content window.
@MainActor
private func isSettingsWindow(_ win: NSWindow) -> Bool {
    SettingsWindowClassifier.isSettings(
        identifier: win.identifier?.rawValue,
        title: win.title,
        isMainWindow: win.isMainWindow,
        isTitled: win.styleMask.contains(.titled)
    )
}

enum SettingsWindowClassifier {
    static func isSettings(identifier: String?, title: String, isMainWindow: Bool, isTitled: Bool) -> Bool {
        if isMainWindow { return false }
        let identifier = identifier ?? ""
        if identifier == "mini-player" { return false }
        if identifier.localizedCaseInsensitiveContains("settings")
            || identifier.localizedCaseInsensitiveContains("preferences") {
            return true
        }
        // Fallback for OS versions that don't tag the identifier: a titled, non-main window whose
        // title names Settings/Preferences. The main window uses a hidden title bar (empty title).
        guard !title.isEmpty, isTitled else { return false }
        return title.localizedCaseInsensitiveContains("settings")
            || title.localizedCaseInsensitiveContains("preferences")
    }
}

extension ParolaAutomationServer {
    func settingsCommands() -> [AutomationCommand] {
        [
            AutomationCommand(
                name: "openSettings",
                area: .settings,
                summary: "Opens the Settings window, optionally focusing a pane, and waits ~300ms for it to appear. Panes hidden in this deployment are not focused and reply with visible: false.",
                kind: .async,
                args: [
                    .init(name: "pane", kind: .string(), required: false, summary: "Settings pane identifier (e.g. 'general', 'dictation', 'localModels')"),
                ],
                handler: { args, ctx in
                    var paneVisible = true
                    if let pane = try args.optionalString("pane"), !pane.isEmpty {
                        guard let route = SettingsRoute(rawValue: pane) else {
                            throw AutomationError.invalidArgs(field: "pane", reason: "unknown settings pane: \(pane)")
                        }
                        paneVisible = route.isVisible(features: ctx.model.features)
                        if paneVisible {
                            ctx.model.settingsPane = pane
                        }
                    }
                    NSApp.activate(ignoringOtherApps: true)
                    if #available(macOS 14.0, *) {
                        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                    } else {
                        NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
                    }

                    var settingsWin = NSApp.windows.first(where: { $0.isVisible && isSettingsWindow($0) })
                    var waitedMs = 0
                    while settingsWin == nil, waitedMs < 800 {
                        try? await Task.sleep(for: .milliseconds(50))
                        waitedMs += 50
                        settingsWin = NSApp.windows.first(where: { $0.isVisible && isSettingsWindow($0) })
                    }

                    return .object([
                        "opened": .bool(settingsWin != nil),
                        "visible": .bool(paneVisible),
                        "visibleCount": .int(NSApp.windows.filter { $0.isVisible }.count),
                        "settingsSize": .object([
                            "w": .int(Int(settingsWin?.frame.width ?? 0)),
                            "h": .int(Int(settingsWin?.frame.height ?? 0)),
                        ]),
                    ])
                }
            ),

            AutomationCommand(
                name: "closeSettings",
                area: .settings,
                summary: "Closes the Settings window only; never the main window.",
                kind: .mutating,
                handler: { _, _ in
                    var closed = false
                    for win in NSApp.windows where win.isVisible && isSettingsWindow(win) {
                        win.close()
                        closed = true
                    }
                    return .object(["closed": .bool(closed)])
                }
            ),

            AutomationCommand(
                name: "setSetting",
                area: .settings,
                summary: "Writes a UserDefaults value through the bridge allowlist.",
                kind: .mutating,
                args: [
                    .init(name: "key", kind: .string(), required: true, summary: "UserDefaults key"),
                    .init(name: "value", kind: .any, required: false, summary: "JSON value to store"),
                ],
                handler: { args, ctx in
                    let key = try args.string("key")
                    guard ParolaAutomationServer.writableSettingKeys.contains(key) else {
                        throw AutomationError.invalidArgs(field: "key", reason: "setting '\(key)' is not writable through the bridge")
                    }
                    let value = args.rawValue("value") ?? .null
                    ctx.model.defaults.set(value.jsonObject, forKey: key)
                    ctx.model.reloadObservedSetting(key: key)
                    return .object(["key": .string(key), "value": value])
                }
            ),

            AutomationCommand(
                name: "setRoute",
                area: .settings,
                summary: "Switches the main app route.",
                kind: .mutating,
                args: [
                    .init(
                        name: "route",
                        kind: .string(enum: AppModel.Route.allCases.map(\.rawValue) + (isTestMode ? ["settings"] : [])),
                        required: true,
                        summary: "Route name"
                    ),
                ],
                handler: { args, ctx in
                    let raw = try args.string("route")
                    if raw == "settings" {
                        guard ctx.model.mode == .test else {
                            throw AutomationError.invalidArgs(field: "route", reason: "unknown route: settings")
                        }
                        ctx.model.settingsRoutePreview = true
                        return .object(["route": .string("settings")])
                    }
                    guard let route = AppModel.Route(rawValue: raw) else {
                        throw AutomationError.invalidArgs(field: "route", reason: "unknown route: \(raw)")
                    }
                    ctx.model.settingsRoutePreview = false
                    // Through the same helpers a sidebar click takes, or the bridge could leave a state no click can.
                    switch route {
                    case .transcript: ctx.model.route = .transcript
                    case .queue: ctx.model.openQueue()
                    case .batch: ctx.model.openBatch()
                    case .statistics: ctx.model.openStatistics()
                    case .recentlyDeleted: ctx.model.openRecentlyDeleted()
                    }
                    return .object(["route": .string(route.rawValue)])
                }
            ),

            AutomationCommand(
                name: "setLibraryFilter",
                area: .settings,
                summary: "Filters the library by category the way the sidebar row does, clearing any search; 'all' or an empty string shows the whole Library page.",
                kind: .mutating,
                args: [
                    .init(name: "category", kind: .string(), required: false, summary: "EntryCategory rawValue, 'all', or empty", defaultValue: .string("")),
                ],
                handler: { args, ctx in
                    let raw = (try args.optionalString("category")) ?? ""
                    if raw.isEmpty {
                        ctx.model.goHome()
                    } else if raw == "all" {
                        ctx.model.browseAll()
                    } else if let cat = EntryCategory(rawValue: raw) {
                        ctx.model.browseCategory(cat)
                    } else {
                        throw AutomationError.invalidArgs(field: "category", reason: "unknown category: \(raw)")
                    }
                    return .object([
                        "libraryFilter": .string(raw),
                        "libraryBrowsingAll": .bool(ctx.model.isBrowsingWholeLibrary),
                    ])
                }
            ),
        ]
    }
}
