import Foundation

#if canImport(FoundationModels)
import FoundationModels
#endif

public enum LanguageModelFactory {
    public enum Failure: LocalizedError, CustomStringConvertible, Sendable {
        case notAvailable(String)

        public var description: String {
            switch self {
            case .notAvailable(let reason): return "Language model unavailable: \(reason)"
            }
        }

        public var errorDescription: String? { description }
    }

    public static func makeOnDevice(instructions: String = "You're a helpful assistant.") throws -> any LanguageModel {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, iOS 26.0, visionOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available:
                let session = LanguageModelSession(instructions: instructions)
                return FoundationLanguageModel(session: session)
            case .unavailable(let reason):
                throw Failure.notAvailable("\(reason)")
            @unknown default:
                throw Failure.notAvailable("Unknown availability state.")
            }
        }
        #endif
        throw Failure.notAvailable("Foundation Models requires macOS 26 / iOS 26 or newer.")
    }
}
