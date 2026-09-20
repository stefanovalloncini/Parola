import Foundation
import Testing
@testable import Parola
import ParolaCore
import ParolaTestSupport

@Suite("Introduction engine choices")
struct IntroductionEngineChoicesTests {
    private static func variant(
        _ id: String,
        engine: EngineID,
        category: ModelCategory = .recommended
    ) -> ModelVariant {
        ModelVariant(
            id: id,
            displayName: id,
            tagline: "",
            engineID: engine,
            sizeBytes: engine == .appleSpeech ? 0 : 1_000,
            downloadSource: ModelDownloadSource(huggingFaceRepo: "repo", subpath: id),
            category: category,
            speedTier: .fast,
            qualityTier: .best
        )
    }

    private static let apple = variant("apple-speech-analyzer", engine: .appleSpeech)
    private static let turbo = variant("openai_whisper-large-v3_turbo", engine: .whisperKit)
    private static let parakeet = variant("nvidia_parakeet", engine: .parakeet, category: .fastest)
    private static let tiny = variant("openai_whisper-tiny", engine: .whisperKit, category: .compact)
    private static let catalog = [turbo, parakeet, tiny, apple]

    private func compute(
        _ catalog: [ModelVariant] = IntroductionEngineChoicesTests.catalog,
        managed: [String: Any] = [:],
        installed: Set<String> = []
    ) -> [String] {
        IntroductionEngineChoices.compute(
            catalog: catalog,
            managed: ManagedConfiguration(plistOverride: managed),
            isInstalled: { installed.contains($0) }
        ).map(\.id)
    }

    @Test("Apple Speech leads, the recommended Whisper follows")
    func bothChoices() {
        #expect(compute() == ["apple-speech-analyzer", "openai_whisper-large-v3_turbo"])
    }

    @Test("a catalog without Apple Speech offers the Whisper alone")
    func whisperOnly() {
        #expect(compute([Self.turbo, Self.parakeet, Self.tiny]) == ["openai_whisper-large-v3_turbo"])
    }

    @Test("only a recommended engine is offered next to Apple Speech")
    func ignoresOtherCategories() {
        #expect(compute([Self.parakeet, Self.tiny, Self.apple]) == ["apple-speech-analyzer"])
    }

    @Test("blocked downloads hide a Whisper that isn't installed")
    func downloadsDisabledHidesUninstalled() {
        #expect(compute(managed: ["disableModelDownloads": true]) == ["apple-speech-analyzer"])
    }

    @Test("blocked downloads keep a Whisper that is already installed")
    func downloadsDisabledKeepsInstalled() {
        let ids = compute(
            managed: ["disableModelDownloads": true],
            installed: ["openai_whisper-large-v3_turbo"]
        )
        #expect(ids == ["apple-speech-analyzer", "openai_whisper-large-v3_turbo"])
    }

    @Test("the engine allowlist decides what is left to choose from")
    func allowlistFilters() {
        #expect(compute(managed: ["allowedEngines": ["whisperkit"]]) == ["openai_whisper-large-v3_turbo"])
        #expect(compute(managed: ["allowedEngines": ["apple-speech"]]) == ["apple-speech-analyzer"])
    }

    @MainActor
    @Test("a deployment with nothing to choose leaves the step out of the introduction")
    func noChoicesDropTheStep() {
        let choices = compute(managed: ["allowedEngines": ["parakeet"]])
        #expect(choices.isEmpty)

        let controller = IntroductionController(
            defaults: temporaryDefaults(),
            mode: .normal,
            showsInTestMode: false,
            hasEngineChoice: !choices.isEmpty,
            environment: [:]
        )
        #expect(controller.steps.contains(.engine) == false)
        #expect(controller.selectedEngineID == nil)
    }
}

@MainActor
@Suite("Introduction engine pick")
struct IntroductionEnginePickTests {
    private func controller(
        choices: [String] = ["apple-speech-analyzer", "openai_whisper-large-v3_turbo"]
    ) -> IntroductionController {
        IntroductionController(
            defaults: temporaryDefaults(),
            mode: .normal,
            showsInTestMode: false,
            engineChoices: choices,
            environment: [:]
        )
    }

    @Test("nothing is picked until a card is clicked")
    func startsWithNoPick() {
        #expect(controller().selectedEngineID == nil)
    }

    @Test("the ring follows the model the app is using now")
    func ringFollowsSelectedModel() {
        let introduction = controller()
        #expect(introduction.ringedEngineID(current: "openai_whisper-large-v3_turbo") == "openai_whisper-large-v3_turbo")
        #expect(introduction.ringedEngineID(current: "nvidia_parakeet-tdt-0.6b-v2") == nil)
    }

    @Test("a click wins over the model the app is using now")
    func clickWinsOverRing() {
        let introduction = controller()
        introduction.chooseEngine("openai_whisper-large-v3_turbo")
        #expect(introduction.ringedEngineID(current: "apple-speech-analyzer") == "openai_whisper-large-v3_turbo")
    }

    @Test("restart clears the click")
    func restartClearsClick() {
        let introduction = controller()
        introduction.chooseEngine("openai_whisper-large-v3_turbo")
        introduction.restart()
        #expect(introduction.selectedEngineID == nil)
    }

    @Test("choosing an offered engine takes")
    func choosesOfferedEngine() {
        let introduction = controller()
        introduction.chooseEngine("openai_whisper-large-v3_turbo")
        #expect(introduction.selectedEngineID == "openai_whisper-large-v3_turbo")
    }

    @Test("an engine that was never offered is ignored")
    func ignoresUnknownEngine() {
        let introduction = controller()
        introduction.chooseEngine("openai_whisper-tiny")
        #expect(introduction.selectedEngineID == nil)
    }
}

@MainActor
@Suite("Committing the introduction's engine")
struct CommitIntroductionEngineTests {
    private func makeModel() -> AppModel {
        AppModel(
            skipBootstrap: true,
            defaults: temporaryDefaults(),
            libraryURL: makeTempLibraryURL("introduction-engine")
        )
    }

    /// Apple Speech ships with macOS, so `ModelStore` always calls it installed — no fixture needed.
    private let installedEngine = "apple-speech-analyzer"

    @Test("an installed engine is activated and nothing downloads")
    func installedEngineOnlyActivates() {
        let model = makeModel()
        model.introduction.selectedEngineID = installedEngine

        model.commitIntroductionEngine()

        #expect(model.selectedModel == installedEngine)
        #expect(model.modelActionError == nil)
        #expect(model.phase == .idle)
    }

    @Test("an engine that isn't installed is activated and downloaded")
    func uninstalledEngineDownloads() {
        let model = makeModel()
        model.introduction.selectedEngineID = "introduction-engine-not-on-disk"
        // Blocks the download before it reaches the network; the refusal is the proof it was asked for.
        model.phase = .transcribing(file: URL(fileURLWithPath: "/dev/null"))

        model.commitIntroductionEngine()

        #expect(model.modelActionError != nil)
        #expect(model.modelActionError == model.downloadBlockedReason)
    }

    @Test("a second commit during the download doesn't ask for it again")
    func commitDuringDownloadIsQuiet() {
        let model = makeModel()
        let id = "introduction-engine-not-on-disk"
        model.introduction.selectedEngineID = id
        model.phase = .downloadingModel(name: id, progress: 0.2)

        model.commitIntroductionEngine()

        #expect(model.selectedModel == id)
        #expect(model.modelActionError == nil)
        #expect(model.phase == .downloadingModel(name: id, progress: 0.2))
    }

    @Test("switching to the other card stops the download the first pick started")
    func commitCancelsTheAbandonedDownload() throws {
        let model = makeModel()
        let choices = model.introduction.engineChoices
        try #require(choices.count == 2)
        model.phase = .downloadingModel(name: choices[1], progress: 0.2)
        model.introduction.selectedEngineID = choices[0]

        model.commitIntroductionEngine()

        #expect(model.phase == .idle)
        #expect(model.selectedModel == choices[0])
        #expect(model.modelActionError == nil)
    }

    @Test("the scan answers whether a model is installed, the store until it lands")
    func installedStateHasOneSource() {
        let model = makeModel()
        #expect(model.isModelInstalled(installedEngine), "Apple Speech ships with macOS")
        #expect(model.isModelInstalled("introduction-engine-not-on-disk") == false)

        model.availableModels = [
            ModelInfo(
                name: "introduction-engine-not-on-disk",
                label: "Pretend",
                approximateSizeBytes: 0,
                isMultilingual: true,
                isInstalled: true
            )
        ]
        #expect(model.isModelInstalled("introduction-engine-not-on-disk"))
    }

    @Test("nothing is committed when no engine was ever picked")
    func noPickCommitsNothing() {
        let model = makeModel()
        let before = model.selectedModel
        model.introduction.selectedEngineID = nil

        model.commitIntroductionEngine()

        #expect(model.selectedModel == before)
        #expect(model.modelActionError == nil)
    }

    @Test("continuing without a click leaves a Parakeet pick alone")
    func noClickLeavesParakeetAlone() {
        let model = makeModel()
        model.activateModel("nvidia_parakeet-tdt-0.6b-v2")

        model.commitIntroductionEngine()

        #expect(model.selectedModel == "nvidia_parakeet-tdt-0.6b-v2")
        #expect(model.modelActionError == nil)
    }

    @Test("restarting the introduction clears the pick and leaves the current model alone")
    func restartClearsPickAndLeavesModelAlone() throws {
        let model = makeModel()
        let choices = model.introduction.engineChoices
        try #require(choices.count == 2)
        model.introduction.chooseEngine(choices[1])
        // The user changes their mind in Settings, then asks for the introduction again.
        model.activateModel(choices[0])

        model.restartIntroduction()

        #expect(model.introduction.selectedEngineID == nil)
        #expect(model.introduction.isPresented)

        model.commitIntroductionEngine()

        #expect(model.selectedModel == choices[0])
        #expect(model.modelActionError == nil)
    }

    @Test("moving on from the engine step commits the pick, other steps don't")
    func advanceCommitsOnTheEngineStep() {
        let model = makeModel()
        model.activateModel("openai_whisper-tiny")
        model.introduction.restart()
        model.introduction.selectedEngineID = installedEngine

        model.advanceIntroduction()
        #expect(model.selectedModel == "openai_whisper-tiny")

        while model.introduction.step != .engine, !model.introduction.isLastStep {
            model.advanceIntroduction()
        }
        #expect(model.introduction.step == .engine)
        model.advanceIntroduction()

        #expect(model.selectedModel == installedEngine)
        #expect(model.introduction.step == .ready)
    }
}
