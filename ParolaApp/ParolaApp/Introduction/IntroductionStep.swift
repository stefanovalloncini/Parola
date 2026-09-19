import Foundation

/// The scenes of the first-run introduction, in the order they are shown. The one place the order
/// is decided: everything else asks `IntroductionController` for `steps`.
enum IntroductionStep: String, CaseIterable, Sendable {
    case hello
    case transcribe
    case features
    case engine
    case ready

    static func sequence(hasEngineChoice: Bool) -> [IntroductionStep] {
        hasEngineChoice ? allCases : allCases.filter { $0 != .engine }
    }
}
