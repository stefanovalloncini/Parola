import Foundation
import AppKit
import ParolaCore

extension ParolaAutomationServer {
    func settingsCommands() -> [AutomationCommand] {
        [
            AutomationCommand(
                name: "openSettings",
                area: .settings,
                summary: "Opens the Settings window, optionally focusing a pane, and waits ~300ms for it to appear.",
                kind: .async,
                args: [
                    .init(name: "pane", kind: .string(), required: false, summary: "Settings pane identifier (e.g. 'general', 'dictation', 'localModels')"),
                ],
                handler: { args, ctx in
                    if let pane = try args.optionalString("pane"), !pane.isEmpty {
                        guard SettingsRoute(rawValue: pane) != nil else {
                            throw AutomationError.invalidArgs(field: "pane", reason: "unknown settings pane: \(pane)")
                        }
                        ctx.model.settingsPane = pane
                    }
                    let visibleCountBefore = NSApp.windows.filter { $0.isVisible }.count
                    if #available(macOS 14.0, *) {
                        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                    } else {
                        NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
                    }
                    try? await Task.sleep(for: .milliseconds(300))
                    let visibleAfter = NSApp.windows.filter { $0.isVisible }
                    let settingsWin = visibleAfter.first(where: { $0.frame.width < 1300 && $0.frame.width > 400 })
                    return .object([
                        "opened": .bool(visibleAfter.count > visibleCountBefore || settingsWin != nil),
                        "visibleCount": .int(visibleAfter.count),
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
                summary: "Closes any visible Settings windows.",
                kind: .mutating,
                handler: { _, _ in
                    var closed = false
                    let mainContent = NSApp.windows.first(where: { $0.frame.width > 1300 && $0.title == "" && !$0.isSheet })
                    for win in NSApp.windows where win.isVisible && win !== mainContent && !win.isSheet {
                        if win.frame.width < 1300 || win.title.contains("Settings") || win.title.contains("Preferences") {
                            win.close()
                            closed = true
                        }
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
                        kind: .string(enum: AppModel.Route.allCases.map(\.rawValue)),
                        required: true,
                        summary: "Route name"
                    ),
                ],
                handler: { args, ctx in
                    let raw = try args.string("route")
                    guard let route = AppModel.Route(rawValue: raw) else {
                        throw AutomationError.invalidArgs(field: "route", reason: "unknown route: \(raw)")
                    }
                    ctx.model.route = route
                    return .object(["route": .string(route.rawValue)])
                }
            ),

            AutomationCommand(
                name: "setLibraryFilter",
                area: .settings,
                summary: "Filters the library by category; empty string clears the filter.",
                kind: .mutating,
                args: [
                    .init(name: "category", kind: .string(), required: false, summary: "EntryCategory rawValue or empty", defaultValue: .string("")),
                ],
                handler: { args, ctx in
                    let raw = (try args.optionalString("category")) ?? ""
                    if raw.isEmpty {
                        ctx.model.libraryFilter = nil
                    } else if let cat = EntryCategory(rawValue: raw) {
                        ctx.model.libraryFilter = cat
                    } else {
                        throw AutomationError.invalidArgs(field: "category", reason: "unknown category: \(raw)")
                    }
                    return .object(["libraryFilter": .string(raw)])
                }
            ),
        ]
    }
}
