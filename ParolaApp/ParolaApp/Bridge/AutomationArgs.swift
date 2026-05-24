import Foundation

struct AutomationArgs: Sendable {
    let values: [String: AutomationValue]

    init(_ values: [String: AutomationValue] = [:]) {
        self.values = values
    }

    init(jsonObject: [String: Any]) {
        var out: [String: AutomationValue] = [:]
        out.reserveCapacity(jsonObject.count)
        for (k, v) in jsonObject { out[k] = AutomationValue(v) }
        self.values = out
    }

    subscript(_ key: String) -> AutomationValue? { values[key] }

    func contains(_ key: String) -> Bool { values[key] != nil }

    func string(_ key: String) throws -> String {
        guard let v = values[key] else {
            throw AutomationError.invalidArgs(field: key, reason: "missing required string")
        }
        if case .string(let s) = v, !s.isEmpty { return s }
        if case .string = v {
            throw AutomationError.invalidArgs(field: key, reason: "must not be empty")
        }
        throw AutomationError.invalidArgs(field: key, reason: "must be a string")
    }

    func optionalString(_ key: String) throws -> String? {
        guard let v = values[key] else { return nil }
        switch v {
        case .null: return nil
        case .string(let s): return s.isEmpty ? nil : s
        default:
            throw AutomationError.invalidArgs(field: key, reason: "must be a string")
        }
    }

    func int(_ key: String) throws -> Int {
        guard let v = values[key] else {
            throw AutomationError.invalidArgs(field: key, reason: "missing required integer")
        }
        switch v {
        case .int(let i): return i
        case .double(let d) where d.rounded() == d: return Int(d)
        default:
            throw AutomationError.invalidArgs(field: key, reason: "must be an integer")
        }
    }

    func optionalInt(_ key: String) throws -> Int? {
        guard let v = values[key] else { return nil }
        switch v {
        case .null: return nil
        case .int(let i): return i
        case .double(let d) where d.rounded() == d: return Int(d)
        default:
            throw AutomationError.invalidArgs(field: key, reason: "must be an integer")
        }
    }

    func double(_ key: String) throws -> Double {
        guard let v = values[key] else {
            throw AutomationError.invalidArgs(field: key, reason: "missing required number")
        }
        switch v {
        case .double(let d): return d
        case .int(let i): return Double(i)
        default:
            throw AutomationError.invalidArgs(field: key, reason: "must be a number")
        }
    }

    func bool(_ key: String) throws -> Bool {
        guard let v = values[key] else {
            throw AutomationError.invalidArgs(field: key, reason: "missing required boolean")
        }
        if case .bool(let b) = v { return b }
        throw AutomationError.invalidArgs(field: key, reason: "must be a boolean")
    }

    func optionalBool(_ key: String) throws -> Bool? {
        guard let v = values[key] else { return nil }
        switch v {
        case .null: return nil
        case .bool(let b): return b
        default:
            throw AutomationError.invalidArgs(field: key, reason: "must be a boolean")
        }
    }

    func stringArray(_ key: String) throws -> [String] {
        guard let v = values[key] else {
            throw AutomationError.invalidArgs(field: key, reason: "missing required string array")
        }
        guard case .array(let items) = v else {
            throw AutomationError.invalidArgs(field: key, reason: "must be an array of strings")
        }
        var out: [String] = []
        out.reserveCapacity(items.count)
        for item in items {
            guard case .string(let s) = item else {
                throw AutomationError.invalidArgs(field: key, reason: "every element must be a string")
            }
            out.append(s)
        }
        return out
    }

    func object(_ key: String) throws -> [String: AutomationValue] {
        guard let v = values[key] else {
            throw AutomationError.invalidArgs(field: key, reason: "missing required object")
        }
        guard case .object(let o) = v else {
            throw AutomationError.invalidArgs(field: key, reason: "must be an object")
        }
        return o
    }

    func rawValue(_ key: String) -> AutomationValue? { values[key] }
}
