import Foundation

enum AutomationValue: Sendable, Equatable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([AutomationValue])
    case object([String: AutomationValue])
}

extension AutomationValue {
    init(_ jsonObject: Any?) {
        guard let jsonObject else { self = .null; return }
        switch jsonObject {
        case is NSNull:
            self = .null
        // JSONSerialization returns every JSON number and boolean as NSNumber, and an
        // NSNumber of 0/1 also bridges `as? Bool` — so a Bool arm here would misdecode
        // numeric 0/1 as false/true. Classify via CFNumberGetType in fromNSNumber instead.
        case let value as NSNumber:
            self = AutomationValue.fromNSNumber(value)
        case let value as String:
            self = .string(value)
        case let value as [Any]:
            self = .array(value.map { AutomationValue($0) })
        case let value as [String: Any]:
            var out: [String: AutomationValue] = [:]
            out.reserveCapacity(value.count)
            for (k, v) in value { out[k] = AutomationValue(v) }
            self = .object(out)
        default:
            self = .string(String(describing: jsonObject))
        }
    }

    private static func fromNSNumber(_ number: NSNumber) -> AutomationValue {
        let typeID = CFNumberGetType(number)
        switch typeID {
        case .charType:
            return .bool(number.boolValue)
        case .floatType, .float32Type, .float64Type, .doubleType, .cgFloatType:
            return .double(number.doubleValue)
        default:
            return .int(number.intValue)
        }
    }

    var jsonObject: Any {
        switch self {
        case .null: return NSNull()
        case .bool(let b): return b
        case .int(let i): return i
        case .double(let d): return d
        case .string(let s): return s
        case .array(let a): return a.map(\.jsonObject)
        case .object(let o):
            var out: [String: Any] = [:]
            out.reserveCapacity(o.count)
            for (k, v) in o { out[k] = v.jsonObject }
            return out
        }
    }
}

extension AutomationValue: Encodable {
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let b): try container.encode(b)
        case .int(let i): try container.encode(i)
        case .double(let d): try container.encode(d)
        case .string(let s): try container.encode(s)
        case .array(let a): try container.encode(a)
        case .object(let o): try container.encode(o)
        }
    }
}
