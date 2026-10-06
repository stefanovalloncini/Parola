import AppKit
import Foundation

struct SettingsTransferFailure: Identifiable {
    enum Operation {
        case export
        case restore
    }

    let id = UUID()
    let operation: Operation
    let message: String
}

enum SettingsExportService {
    private static let exportedKeys: [String] = {
        var keys: Set<String> = []
        for scope in SettingsPaneScope.allCases {
            for key in scope.defaultsKeys {
                keys.insert(key)
            }
        }
        keys.formUnion(UnscopedSettingsKeys.all)
        return Array(keys).sorted()
    }()

    @MainActor
    static func presentExportPanel() -> SettingsTransferFailure? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "parola.parola-settings"
        panel.allowedContentTypes = []
        panel.message = String(localized: "Save Parola settings")
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        let payload = exportPayload()
        do {
            let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: url, options: .atomic)
            return nil
        } catch {
            return SettingsTransferFailure(operation: .export, message: error.localizedDescription)
        }
    }

    @MainActor
    static func presentImportPanel() -> SettingsTransferFailure? {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.message = String(localized: "Pick a .parola-settings file")
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        do {
            let data = try Data(contentsOf: url)
            guard let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw NSError(domain: "ParolaSettings", code: -1, userInfo: [NSLocalizedDescriptionKey: String(localized: "Not a valid settings file.")])
            }
            apply(payload)
            return nil
        } catch {
            return SettingsTransferFailure(operation: .restore, message: error.localizedDescription)
        }
    }

    static func exportPayload(defaults: UserDefaults = DefaultsStore.current) -> [String: Any] {
        var payload: [String: Any] = [:]
        for key in exportedKeys {
            guard let value = defaults.object(forKey: key) else { continue }
            payload[key] = encode(value)
        }
        return payload
    }

    private static func encode(_ value: Any) -> Any {
        if let data = value as? Data {
            return ["__type": "data", "value": data.base64EncodedString()]
        }
        return value
    }

    @MainActor
    static func apply(_ payload: [String: Any], defaults: UserDefaults = DefaultsStore.current) {
        let allowed = Set(exportedKeys)
        // Additive: only overwrite keys the file carries; absent keys keep their current value.
        for (key, raw) in payload where allowed.contains(key) {
            if let envelope = raw as? [String: Any],
               envelope["__type"] as? String == "data",
               let base64 = envelope["value"] as? String,
               let data = Data(base64Encoded: base64) {
                defaults.set(data, forKey: key)
            } else {
                defaults.set(raw, forKey: key)
            }
        }
        NotificationCenter.default.post(name: .parolaSettingsReset, object: nil)
    }
}
