import Foundation

/// How a transcript's language was decided when the caller left it unset. `detected` means the
/// engine inferred it from the audio; `assumed` means it could not, and the code is a fallback the
/// frontend should surface so the user can set the language by hand and re-run. A nil
/// `Transcript.languageDetection` means the run had nothing to report — the caller named the
/// language, or the engine does not answer the question.
public enum LanguageDetection: Hashable, Sendable {
    case detected(String)
    case assumed(String)

    public var code: String {
        switch self {
        case .detected(let code), .assumed(let code): code
        }
    }

    public var isAssumed: Bool {
        if case .assumed = self { return true }
        return false
    }
}

extension LanguageDetection: Codable {
    private enum CodingKeys: String, CodingKey {
        case status
        case code
    }

    private enum Status: String, Codable {
        case detected
        case assumed
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let code = try container.decode(String.self, forKey: .code)
        switch try container.decode(Status.self, forKey: .status) {
        case .detected: self = .detected(code)
        case .assumed: self = .assumed(code)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(isAssumed ? Status.assumed : Status.detected, forKey: .status)
        try container.encode(code, forKey: .code)
    }
}
