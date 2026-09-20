import Foundation

/// Drives the first-run introduction: which scene is on screen, whether it's on screen at all, and the flag that remembers it finished.
@MainActor
@Observable
final class IntroductionController {
    static let completionKey = "introductionComplete"
    private static let welcomeKey = "hasSeenWelcome"

    let steps: [IntroductionStep]

    /// Model ids the engine scene offers, in the order it shows them.
    let engineChoices: [String]

    /// An explicit click on an engine card, nil until one happens; reaches the app on Continue, through `AppModel.commitIntroductionEngine()`.
    var selectedEngineID: String?

    /// A launch that must never show the introduction on its own — a unit-test process, or a test-mode instance that didn't ask for it — until an explicit `restart()`.
    private(set) var isSuppressed: Bool

    private(set) var isComplete: Bool
    private(set) var step: IntroductionStep

    /// Which way the last move went, so the stage can mirror its scene transition.
    private(set) var isMovingBack = false

    /// Set for this launch only, when something else (an opened URL) needs the main window.
    private(set) var isDeferred = false

    @ObservationIgnored private let defaults: UserDefaults

    init(
        defaults: UserDefaults,
        mode: AppBootstrap.Mode,
        showsInTestMode: Bool,
        hasEngineChoice: Bool = true,
        engineChoices: [String] = [],
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

    /// The card to ring: an explicit click, or the current model when it's one of the choices — never a fallback to the first card.
    func ringedEngineID(current: String) -> String? {
        selectedEngineID ?? (engineChoices.contains(current) ? current : nil)
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
        selectedEngineID = nil
    }

    func `defer`() {
        guard !isDeferred else { return }
        isDeferred = true
    }

    /// Follows a Reset or an Import that rewrote the flag underneath us. Reads, never writes.
    func reloadFromDefaults() {
        isComplete = defaults.bool(forKey: Self.completionKey)
        selectedEngineID = nil
    }

    private func setComplete(_ value: Bool) {
        isComplete = value
        defaults.set(value, forKey: Self.completionKey)
    }
}
