import Foundation
import ParolaCore

/// What a destination editor's Check Connection or Send Test found, worded for the person.
struct EditorCheckResult: Equatable {
    let ok: Bool
    let message: String
}

extension AppModel {

    func writeDestinationSecrets(_ values: [String: String]) async throws {
        for (reference, value) in values where !value.isEmpty {
            try await deliveryEnvironment.secrets.set(value, for: reference)
        }
    }

    func hasSavedSecret(_ reference: String) async -> Bool {
        ((try? await deliveryEnvironment.secrets.get(reference)) ?? nil)?.isEmpty == false
    }

    /// Unsaved editor values stand in for the Keychain, so a new destination can be tested before it exists.
    func sendWebhookTest(_ destination: WebhookDestination, unsavedSecrets: [String: String]) async -> EditorCheckResult {
        guard destinationsEnabled else { return EditorCheckResult(ok: false, message: String(localized: "Send To is turned off.")) }
        let bound = AnyDestination.webhook(destination).bound(to: deliveryEnvironment.withSecretOverrides(unsavedSecrets))
        guard case .webhook(let hook) = bound else { return EditorCheckResult(ok: false, message: "") }
        do {
            let status = try await hook.sendTest(Self.sampleDeliveryPayload())
            if (200..<300).contains(status) {
                return EditorCheckResult(ok: true, message: String(localized: "The server answered HTTP \(status)."))
            }
            return EditorCheckResult(ok: false, message: String(localized: "The server answered HTTP \(status), so it did not take the sample."))
        } catch {
            return EditorCheckResult(ok: false, message: FailureText.message(for: error))
        }
    }

    func checkNotionConnection(_ destination: NotionDestination, unsavedSecrets: [String: String]) async -> EditorCheckResult {
        guard destinationsEnabled else { return EditorCheckResult(ok: false, message: String(localized: "Send To is turned off.")) }
        guard case .notion(let notion) = AnyDestination.notion(destination).bound(to: deliveryEnvironment.withSecretOverrides(unsavedSecrets)) else {
            return EditorCheckResult(ok: false, message: "")
        }
        do {
            switch try await notion.checkConnection() {
            case .connected(let title?):
                return EditorCheckResult(ok: true, message: String(localized: "Connected. Parola can add pages under “\(title)”."))
            case .connected(nil):
                return EditorCheckResult(ok: true, message: String(localized: "Connected. Parola can add pages under that page."))
            case .unauthorised:
                return EditorCheckResult(ok: false, message: String(localized: "Notion didn't accept the secret. Copy it again from your integration's settings."))
            case .pageNotShared:
                return EditorCheckResult(ok: false, message: String(localized: "Notion can't see that page. Open it in Notion, choose the ••• menu, then Connections, and add your integration."))
            }
        } catch {
            return EditorCheckResult(ok: false, message: FailureText.message(for: error))
        }
    }

    func checkObsidianRESTConnection(_ destination: ObsidianLocalRESTDestination, unsavedSecrets: [String: String]) async -> EditorCheckResult {
        guard destinationsEnabled else { return EditorCheckResult(ok: false, message: String(localized: "Send To is turned off.")) }
        guard case .obsidianREST(let rest) = AnyDestination.obsidianREST(destination).bound(to: deliveryEnvironment.withSecretOverrides(unsavedSecrets)) else {
            return EditorCheckResult(ok: false, message: "")
        }
        do {
            switch try await rest.checkConnection() {
            case .connected:
                return EditorCheckResult(ok: true, message: String(localized: "Connected to the Local REST API plugin."))
            case .unauthorised, .pageNotShared:
                return EditorCheckResult(ok: false, message: String(localized: "The plugin answered, but it didn't accept the API key."))
            }
        } catch {
            return EditorCheckResult(ok: false, message: FailureText.message(for: error))
        }
    }

    func sendObsidianRESTTestNote(_ destination: ObsidianLocalRESTDestination, unsavedSecrets: [String: String]) async -> EditorCheckResult {
        guard destinationsEnabled else { return EditorCheckResult(ok: false, message: String(localized: "Send To is turned off.")) }
        guard case .obsidianREST(let rest) = AnyDestination.obsidianREST(destination).bound(to: deliveryEnvironment.withSecretOverrides(unsavedSecrets)) else {
            return EditorCheckResult(ok: false, message: "")
        }
        do {
            _ = try await rest.deliver(Self.sampleDeliveryPayload())
            return EditorCheckResult(ok: true, message: String(localized: "Wrote a test note to the vault."))
        } catch {
            return EditorCheckResult(ok: false, message: FailureText.message(for: error))
        }
    }
}
