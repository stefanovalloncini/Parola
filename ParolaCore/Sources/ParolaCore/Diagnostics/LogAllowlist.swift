import Foundation

enum LogAllowlist {
    static let unrecognized = "unrecognized"

    private static let knownEngineIDs: Set<String> = [
        EngineID.whisperKit.rawValue, EngineID.parakeet.rawValue, EngineID.appleSpeech.rawValue,
    ]

    static func modelID(_ id: String) -> String {
        ModelCatalog.variant(id: id) != nil ? id : unrecognized
    }

    static func engineID(_ id: String) -> String {
        knownEngineIDs.contains(id) ? id : unrecognized
    }

    static func languageCode(_ code: String) -> String {
        guard code.count <= 35 else { return unrecognized }
        let pattern = #"^[a-z]{2,3}(-[a-zA-Z0-9]{2,8})*$"#
        return code.range(of: pattern, options: .regularExpression) != nil ? code : unrecognized
    }
}
