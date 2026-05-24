import Foundation

enum AutomationError: Error {
    case invalidArgs(field: String, reason: String)
    case unknownCommand(String)
    case precondition(String)
    case permission(String)
    case notFound(kind: String, id: String)
    case timeout(observed: [String: AutomationValue])
    case `internal`(String)
    case appDead(String)
}

extension AutomationError {
    var code: String {
        switch self {
        case .invalidArgs: return "INVALID_ARGS"
        case .unknownCommand: return "UNKNOWN_COMMAND"
        case .precondition: return "PRECONDITION"
        case .permission: return "PERMISSION"
        case .notFound: return "NOT_FOUND"
        case .timeout: return "TIMEOUT"
        case .internal: return "INTERNAL"
        case .appDead: return "APP_DEAD"
        }
    }

    var message: String {
        switch self {
        case .invalidArgs(let field, let reason):
            return "Invalid args for '\(field)': \(reason)"
        case .unknownCommand(let cmd):
            return "Unknown command: \(cmd)"
        case .precondition(let reason):
            return reason
        case .permission(let reason):
            return reason
        case .notFound(let kind, let id):
            return "\(kind) not found: \(id)"
        case .timeout:
            return "Operation timed out."
        case .internal(let reason):
            return reason
        case .appDead(let reason):
            return reason
        }
    }

    var details: [String: AutomationValue] {
        switch self {
        case .invalidArgs(let field, let reason):
            return ["field": .string(field), "reason": .string(reason)]
        case .unknownCommand(let cmd):
            return ["command": .string(cmd)]
        case .precondition, .permission, .internal, .appDead:
            return [:]
        case .notFound(let kind, let id):
            return ["kind": .string(kind), "id": .string(id)]
        case .timeout(let observed):
            return observed
        }
    }

    struct Wire: Encodable {
        let code: String
        let message: String
        let details: [String: AutomationValue]
    }

    var wire: Wire {
        Wire(code: code, message: message, details: details)
    }
}
