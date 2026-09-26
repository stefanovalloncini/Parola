import Foundation

/// The user's transcript rules and the language fixes, in the one order every surface uses: user
/// rules first, so a rule written against what the engine emitted ("perchè") still matches, and
/// the orthography pass last.
public struct TranscriptPostProcessor: Sendable, Hashable {
    public var ignoredRules: [IgnoredSegmentRule]
    public var findReplaceRules: [FindReplaceRule]

    public init(ignoredRules: [IgnoredSegmentRule] = [], findReplaceRules: [FindReplaceRule] = []) {
        self.ignoredRules = ignoredRules
        self.findReplaceRules = findReplaceRules
    }

    /// What a surface with no user rules of its own applies: the CLI and the MCP server.
    public static let orthographyOnly = TranscriptPostProcessor()

    public func apply(_ transcript: Transcript) -> Transcript {
        var out = transcript
        out.segments = IgnoredSegments.apply(rules: ignoredRules, to: out.segments)
        out.segments = GlobalFindReplace.apply(rules: findReplaceRules, to: out.segments)
        out.segments = ItalianOrthography.apply(to: out.segments, language: out.language)
        return out
    }

    /// The same pass off the caller's actor, so a long transcript's regex work can't hitch the
    /// main thread as results land.
    @concurrent
    public func applyOffActor(_ transcript: Transcript) async -> Transcript {
        apply(transcript)
    }
}
