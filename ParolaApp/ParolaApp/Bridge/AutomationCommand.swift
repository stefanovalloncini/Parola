import Foundation

struct AutomationCommand: Sendable {
    enum Kind: Sendable { case sync, mutating, async, waiter }

    enum Area: String, Sendable {
        case core, model, transcript, library, batch, recording,
             dictation, prompt, settings, window, test, lifecycle
    }

    struct Argument: Sendable {
        enum Kind: Sendable {
            case string(enum: [String]? = nil)
            case boolean
            case integer
            case double
            case stringArray
            case object
            case any
        }

        let name: String
        let kind: Kind
        let required: Bool
        let summary: String
        let defaultValue: AutomationValue?

        init(
            name: String,
            kind: Kind,
            required: Bool,
            summary: String,
            defaultValue: AutomationValue? = nil
        ) {
            self.name = name
            self.kind = kind
            self.required = required
            self.summary = summary
            self.defaultValue = defaultValue
        }
    }

    let name: String
    let area: Area
    let summary: String
    let kind: Kind
    let args: [Argument]
    let followsWith: [String]
    let handler: @MainActor @Sendable (AutomationArgs, AutomationContext) async throws -> AutomationValue

    init(
        name: String,
        area: Area,
        summary: String,
        kind: Kind,
        args: [Argument] = [],
        followsWith: [String] = [],
        handler: @escaping @MainActor @Sendable (AutomationArgs, AutomationContext) async throws -> AutomationValue
    ) {
        self.name = name
        self.area = area
        self.summary = summary
        self.kind = kind
        self.args = args
        self.followsWith = followsWith
        self.handler = handler
    }

    func validate(_ args: AutomationArgs) throws -> AutomationArgs {
        var merged = args.values
        for arg in self.args {
            if let provided = args[arg.name] {
                try checkType(arg, value: provided)
            } else if let fallback = arg.defaultValue {
                merged[arg.name] = fallback
            } else if arg.required {
                throw AutomationError.invalidArgs(field: arg.name, reason: "missing required \(typeLabel(arg.kind))")
            }
        }
        return AutomationArgs(merged)
    }

    private func checkType(_ arg: Argument, value: AutomationValue) throws {
        switch (arg.kind, value) {
        case (.any, _), (_, .null):
            return
        case (.boolean, .bool):
            return
        case (.integer, .int):
            return
        case (.integer, .double(let d)) where d.rounded() == d:
            return
        case (.double, .double), (.double, .int):
            return
        case (.string(let allowed), .string(let s)):
            if let allowed, !allowed.contains(s) {
                throw AutomationError.invalidArgs(field: arg.name, reason: "must be one of: \(allowed.joined(separator: ", "))")
            }
        case (.stringArray, .array(let items)):
            for item in items {
                guard case .string = item else {
                    throw AutomationError.invalidArgs(field: arg.name, reason: "every element must be a string")
                }
            }
        case (.object, .object):
            return
        default:
            throw AutomationError.invalidArgs(field: arg.name, reason: "must be \(typeLabel(arg.kind))")
        }
    }

    private func typeLabel(_ kind: Argument.Kind) -> String {
        switch kind {
        case .string: return "a string"
        case .boolean: return "a boolean"
        case .integer: return "an integer"
        case .double: return "a number"
        case .stringArray: return "an array of strings"
        case .object: return "an object"
        case .any: return "a JSON value"
        }
    }
}
