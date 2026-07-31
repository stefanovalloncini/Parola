import Foundation
import ParolaCore

@MainActor
struct AutomationContext {
    let model: AppModel
    unowned let server: ParolaAutomationServer

    /// Gated bridge commands refuse with a structured error instead of a silent no-op.
    func require(_ feature: ParolaFeature) throws {
        guard model.features.isEnabled(feature) else {
            throw AutomationError.precondition(ParolaError.featureDisabled(feature).description)
        }
    }
}
