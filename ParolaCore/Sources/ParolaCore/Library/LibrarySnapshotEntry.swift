import Foundation

/// One entry file of the search index snapshot, as `JSONEncoder` writes it.
struct SnapshotEntry: Codable, Sendable, Equatable {
    let id: String
    let title: String
    let excerpt: String?
    let bodyBytes: Int
    let bodyHash: UInt64
    let tokens: [String]
    let counts: [UInt32]
    let offsets: [Int32]
    let boundaryOffsets: [Int32]
    let boundaryCentiseconds: [UInt32]
    let fingerprint: String

    /// nil for anything the fast reader does not take for certain; the caller then decodes with `JSONDecoder`.
    init?(scanning data: Data) {
        let scanned = data.withUnsafeBytes { SnapshotEntryScanner.scan($0.bindMemory(to: UInt8.self)) }
        guard let scanned else { return nil }
        self = scanned
    }

    init(
        id: String, title: String, excerpt: String?, bodyBytes: Int, bodyHash: UInt64, tokens: [String],
        counts: [UInt32], offsets: [Int32], boundaryOffsets: [Int32], boundaryCentiseconds: [UInt32], fingerprint: String
    ) {
        self.id = id
        self.title = title
        self.excerpt = excerpt
        self.bodyBytes = bodyBytes
        self.bodyHash = bodyHash
        self.tokens = tokens
        self.counts = counts
        self.offsets = offsets
        self.boundaryOffsets = boundaryOffsets
        self.boundaryCentiseconds = boundaryCentiseconds
        self.fingerprint = fingerprint
    }

    static func decode(_ data: Data) -> SnapshotEntry? {
        SnapshotEntry(scanning: data) ?? (try? JSONDecoder().decode(SnapshotEntry.self, from: data))
    }
}

/// Reads the one object shape the index writes without the generic `Decodable` machinery, which cost more than the file reads.
private struct SnapshotEntryScanner {
    private let bytes: UnsafeBufferPointer<UInt8>
    private var position = 0

    private init(_ bytes: UnsafeBufferPointer<UInt8>) { self.bytes = bytes }

    static func scan(_ bytes: UnsafeBufferPointer<UInt8>) -> SnapshotEntry? {
        var scanner = SnapshotEntryScanner(bytes)
        return scanner.entry()
    }

    private enum Key: String {
        case id, title, excerpt, bodyBytes, bodyHash, tokens, counts, offsets, boundaryOffsets, boundaryCentiseconds, fingerprint
    }

    private mutating func entry() -> SnapshotEntry? {
        var id: String?
        var title: String?
        var excerpt: String?
        var bodyBytes: Int?
        var bodyHash: UInt64?
        var tokens: [String]?
        var counts: [UInt32]?
        var offsets: [Int32]?
        var boundaryOffsets: [Int32]?
        var boundaryCentiseconds: [UInt32]?
        var fingerprint: String?
        var seen = Set<Key>()

        skipWhitespace()
        guard consume(UInt8(ascii: "{")) else { return nil }
        skipWhitespace()
        if !consume(UInt8(ascii: "}")) {
            repeat {
                skipWhitespace()
                guard let name = string(), let key = Key(rawValue: name), seen.insert(key).inserted else { return nil }
                skipWhitespace()
                guard consume(UInt8(ascii: ":")) else { return nil }
                skipWhitespace()
                switch key {
                case .id: id = string()
                case .title: title = string()
                case .excerpt:
                    if !consumeLiteral("null") {
                        guard let value = string() else { return nil }
                        excerpt = value
                    }
                case .bodyBytes: bodyBytes = integer(Int.self)
                case .bodyHash: bodyHash = integer(UInt64.self)
                case .tokens: tokens = strings()
                case .counts: counts = integers(UInt32.self)
                case .offsets: offsets = integers(Int32.self)
                case .boundaryOffsets: boundaryOffsets = integers(Int32.self)
                case .boundaryCentiseconds: boundaryCentiseconds = integers(UInt32.self)
                case .fingerprint: fingerprint = string()
                }
                skipWhitespace()
            } while consume(UInt8(ascii: ","))
            guard consume(UInt8(ascii: "}")) else { return nil }
        }
        skipWhitespace()
        guard position == bytes.count else { return nil }
        guard let id, let title, let bodyBytes, let bodyHash, let tokens, let counts,
              let offsets, let boundaryOffsets, let boundaryCentiseconds, let fingerprint else { return nil }
        return SnapshotEntry(
            id: id, title: title, excerpt: excerpt, bodyBytes: bodyBytes, bodyHash: bodyHash, tokens: tokens,
            counts: counts, offsets: offsets, boundaryOffsets: boundaryOffsets,
            boundaryCentiseconds: boundaryCentiseconds, fingerprint: fingerprint
        )
    }

    private mutating func skipWhitespace() {
        while position < bytes.count {
            switch bytes[position] {
            case 0x20, 0x09, 0x0A, 0x0D: position += 1
            default: return
            }
        }
    }

    private mutating func consume(_ byte: UInt8) -> Bool {
        guard position < bytes.count, bytes[position] == byte else { return false }
        position += 1
        return true
    }

    private mutating func consumeLiteral(_ literal: StaticString) -> Bool {
        let count = literal.utf8CodeUnitCount
        guard position + count <= bytes.count else { return false }
        let matches = literal.withUTF8Buffer { expected in
            (0..<count).allSatisfy { bytes[position + $0] == expected[$0] }
        }
        guard matches else { return false }
        position += count
        return true
    }

    /// Plain runs are taken as they are; `\"`, `\\`, `\/` and the control escapes are resolved; `\u` leaves the file to `JSONDecoder`.
    private mutating func string() -> String? {
        guard consume(UInt8(ascii: "\"")) else { return nil }
        let start = position
        while position < bytes.count {
            let byte = bytes[position]
            if byte == UInt8(ascii: "\"") {
                let run = UnsafeBufferPointer(rebasing: bytes[start..<position])
                position += 1
                return Self.validated(run)
            }
            if byte == UInt8(ascii: "\\") { return escapedString(from: start) }
            if byte < 0x20 { return nil }
            position += 1
        }
        return nil
    }

    private static func validated(_ run: UnsafeBufferPointer<UInt8>) -> String? {
        let string = String(decoding: run, as: UTF8.self)
        if !run.contains(where: { $0 >= 0x80 }) { return string }
        return string.utf8.elementsEqual(run) ? string : nil
    }

    private mutating func escapedString(from start: Int) -> String? {
        var out = Array(bytes[start..<position])
        while position < bytes.count {
            let byte = bytes[position]
            position += 1
            switch byte {
            case UInt8(ascii: "\""):
                return out.withUnsafeBufferPointer { Self.validated($0) }
            case UInt8(ascii: "\\"):
                guard position < bytes.count else { return nil }
                let escaped = bytes[position]
                position += 1
                switch escaped {
                case UInt8(ascii: "\""), UInt8(ascii: "\\"), UInt8(ascii: "/"): out.append(escaped)
                case UInt8(ascii: "n"): out.append(0x0A)
                case UInt8(ascii: "r"): out.append(0x0D)
                case UInt8(ascii: "t"): out.append(0x09)
                case UInt8(ascii: "b"): out.append(0x08)
                case UInt8(ascii: "f"): out.append(0x0C)
                default: return nil
                }
            case 0..<0x20:
                return nil
            default:
                out.append(byte)
            }
        }
        return nil
    }

    private mutating func integer<T: FixedWidthInteger>(_ type: T.Type) -> T? {
        let negative = consume(UInt8(ascii: "-"))
        if negative, !T.isSigned { return nil }
        guard position < bytes.count, bytes[position] >= 0x30, bytes[position] <= 0x39 else { return nil }
        if bytes[position] == 0x30, position + 1 < bytes.count, bytes[position + 1] >= 0x30, bytes[position + 1] <= 0x39 { return nil }
        var value: T = 0
        while position < bytes.count, bytes[position] >= 0x30, bytes[position] <= 0x39 {
            let digit = T(bytes[position] - 0x30)
            let (scaled, scaleOverflow) = value.multipliedReportingOverflow(by: 10)
            let (next, addOverflow) = negative ? scaled.subtractingReportingOverflow(digit) : scaled.addingReportingOverflow(digit)
            if scaleOverflow || addOverflow { return nil }
            value = next
            position += 1
        }
        if position < bytes.count, bytes[position] == UInt8(ascii: ".") || bytes[position] | 0x20 == UInt8(ascii: "e") { return nil }
        return value
    }

    private mutating func integers<T: FixedWidthInteger>(_ type: T.Type) -> [T]? {
        guard consume(UInt8(ascii: "[")) else { return nil }
        var values: [T] = []
        skipWhitespace()
        if consume(UInt8(ascii: "]")) { return values }
        repeat {
            skipWhitespace()
            guard let value = integer(T.self) else { return nil }
            values.append(value)
            skipWhitespace()
        } while consume(UInt8(ascii: ","))
        return consume(UInt8(ascii: "]")) ? values : nil
    }

    private mutating func strings() -> [String]? {
        guard consume(UInt8(ascii: "[")) else { return nil }
        var values: [String] = []
        skipWhitespace()
        if consume(UInt8(ascii: "]")) { return values }
        repeat {
            skipWhitespace()
            guard let value = string() else { return nil }
            values.append(value)
            skipWhitespace()
        } while consume(UInt8(ascii: ","))
        return consume(UInt8(ascii: "]")) ? values : nil
    }
}
