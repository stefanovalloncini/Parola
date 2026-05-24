import Foundation

@MainActor
struct AutomationContext {
    let model: AppModel
    unowned let server: ParolaAutomationServer
}
