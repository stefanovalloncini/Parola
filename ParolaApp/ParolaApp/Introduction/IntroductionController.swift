import Foundation

/// Drives the first-run introduction: which scene is on screen, whether it is on screen at all, and
/// the one flag that remembers it was finished.
@MainActor
@Observable
final class IntroductionController {
    static let completionKey = "introductionComplete"
    private static let welcomeKey = "hasSeenWelcome"

    let steps: [IntroductionStep]

    /// Model ids the engine scene offers, in the order it shows them.
    let engineChoices: [String]

    /// The card with the ring on it. Lives for this run only: the pick reaches the app when the
    /// user moves on, through `AppModel.commitIntroductionEngine()`.
    var selectedEngineID: String?

    /// A launch that must never show the introduction on its own: a unit-test process, or a
    /// test-mode instance that did not ask for it. An explicit `restart()` overrules it.
    private(set) var isSuppressed: Bool

    private(set) var isComplete: Bool
    private(set) var step: IntroductionStep

    /// Which way the last move went, so the stage can mirror its scene transition.
    private(set) var isMovingBack = false

    /// Set for this launch only, when something else (an opened URL) needs the main window.
    var isDeferred = false

    @ObservationIgnored private let defaults: UserDefaults

    init(
        defaults: UserDefaults,
        mode: AppBootstrap.Mode,
        showsInTestMode: Bool,
        hasEngineChoice: Bool = true,
        engineChoices: [String] = [],
        preferredEngineID: String? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.defaults = defaults
        self.steps = IntroductionStep.sequence(hasEngineChoice: hasEngineChoice)
        self.engineChoices = engineChoices
        self.isSuppressed = environment["XCTestConfigurationFilePath"] != nil
            || (mode == .test && !showsInTestMode)

        if defaults.object(forKey: Self.completionKey) == nil, defaults.bool(forKey: Self.welcomeKey) {
            self.isComplete = true
            defaults.set(true, forKey: Self.completionKey)
            // Retiring the old key is what lets Reset ▸ all bring the introduction back for an upgrader.
            defaults.removeObject(forKey: Self.welcomeKey)
        } else {
            self.isComplete = defaults.bool(forKey: Self.completionKey)
        }

        var opening = steps[0]
        #if DEBUG
        if let name = environment["PAROLA_INTRODUCTION_STEP"],
           let wanted = IntroductionStep(rawValue: name),
           steps.contains(wanted) {
            opening = wanted
        }
        #endif
        self.step = opening
        presetEngine(preferredEngineID)
    }

    var isPresented: Bool { !isComplete && !isDeferred && !isSuppressed }

    var stepIndex: Int { steps.firstIndex(of: step) ?? 0 }
    var canGoBack: Bool { stepIndex > 0 }
    var isLastStep: Bool { stepIndex == steps.count - 1 }

    func advance() {
        guard stepIndex + 1 < steps.count else { return }
        isMovingBack = false
        step = steps[stepIndex + 1]
    }

    func back() {
        guard canGoBack else { return }
        isMovingBack = true
        step = steps[stepIndex - 1]
    }

    func chooseEngine(_ id: String) {
        guard engineChoices.contains(id) else { return }
        selectedEngineID = id
    }

    /// Starts the pick from the model the app is using now: the introduction can be re-run long after
    /// launch, and the engine it last preset may be nothing like the current selection.
    func presetEngine(_ id: String?) {
        selectedEngineID = engineChoices.contains(id ?? "") ? id : engineChoices.first
    }

    func skip() {
        finish()
    }

    func finish() {
        setComplete(true)
        isMovingBack = false
        step = steps[0]
    }

    func restart() {
        setComplete(false)
        isDeferred = false
        isSuppressed = false
        isMovingBack = false
        step = steps[0]
    }

    func `defer`() {
        isDeferred = true
    }

    /// Follows a Reset or an Import that rewrote the flag underneath us. Reads, never writes.
    func reloadFromDefaults() {
        isComplete = defaults.bool(forKey: Self.completionKey)
    }

    private func setComplete(_ value: Bool) {
        isComplete = value
        defaults.set(value, forKey: Self.completionKey)
    }
}
