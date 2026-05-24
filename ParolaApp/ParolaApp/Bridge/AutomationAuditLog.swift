import Foundation

actor AutomationAuditLog {
    func record(
        id: String,
        command: String,
        args: AutomationArgs,
        ok: Bool,
        elapsedMs: Int,
        errorCode: String? = nil
    ) {
    }
}
