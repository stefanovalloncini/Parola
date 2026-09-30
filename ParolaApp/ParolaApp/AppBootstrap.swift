import Foundation
import ParolaCore

struct AppBootstrap: @unchecked Sendable {
    enum Mode: Sendable { case normal, test }

    let mode: Mode
    let library: URL?
    let models: URL?
    let defaultsSuite: String?
    nonisolated(unsafe) let defaultsOverride: UserDefaults?  // UserDefaults is documented thread-safe; Foundation just hasn't marked it Sendable.
    let sideEffects: Set<BootstrapSideEffect>
    let filePicker: FilePicker
    let clock: any Clock<Duration>  // `any Clock<Duration>` isn't Sendable-marked, but the clocks we hand out (ContinuousClock, TestClock, ImmediateClock) are all immutable, safe-to-share instances.
    let enabledFeaturesOverride: Set<ParolaFeature>?
    let fileReadDeadline: Duration
    /// Test mode hides the first-run introduction; this flag is how a sandbox asks for it back.
    let showsIntroduction: Bool
    /// Where API keys are read and written. Left nil, a test-mode launch keeps them in memory and
    /// a normal launch uses the keychain, so a sandbox never writes into the real one.
    let apiKeyStore: (any APIKeyStore)?
    /// Nil fetches links through yt-dlp.
    let linkFetcher: (any LinkFetcher)?

    init(
        mode: Mode,
        library: URL? = nil,
        models: URL? = nil,
        defaultsSuite: String? = nil,
        defaultsOverride: UserDefaults? = nil,
        sideEffects: Set<BootstrapSideEffect>,
        filePicker: FilePicker,
        clock: any Clock<Duration> = ContinuousClock(),
        enabledFeaturesOverride: Set<ParolaFeature>? = nil,
        fileReadDeadline: Duration = FileReadDeadline.header,
        showsIntroduction: Bool = false,
        apiKeyStore: (any APIKeyStore)? = nil,
        linkFetcher: (any LinkFetcher)? = nil
    ) {
        self.mode = mode
        self.library = library
        self.models = models
        self.defaultsSuite = defaultsSuite
        self.defaultsOverride = defaultsOverride
        self.sideEffects = sideEffects
        self.filePicker = filePicker
        self.clock = clock
        self.enabledFeaturesOverride = enabledFeaturesOverride
        self.fileReadDeadline = fileReadDeadline
        self.showsIntroduction = showsIntroduction
        self.apiKeyStore = apiKeyStore
        self.linkFetcher = linkFetcher
    }

    static let normal: AppBootstrap = AppBootstrap(
        mode: .normal,
        sideEffects: BootstrapSideEffect.all,
        filePicker: SystemFilePicker()
    )

    /// A `--test-mode` launch reads its sandbox from the flags; the unit-test host gets one of its own.
    static func test(
        from args: [String],
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> AppBootstrap? {
        guard args.contains("--test-mode") else { return testHost(environment: environment) }
        let map = parseKeyValueFlags(args)
        return AppBootstrap(
            mode: .test,
            library: map["--library"].map { URL(fileURLWithPath: $0) },
            models: map["--models"].map { URL(fileURLWithPath: $0) },
            defaultsSuite: map["--defaults-suite"],
            defaultsOverride: nil,
            sideEffects: BootstrapSideEffect.testing,
            filePicker: TestFilePicker(),
            clock: ContinuousClock(),
            enabledFeaturesOverride: map["--enabled-features"].map { raw in
                Set(raw.split(separator: ",").compactMap { ParolaFeature(rawValue: String($0)) })
            },
            showsIntroduction: args.contains("--show-introduction")
        )
    }

    /// Every test builds its own AppModel; the host's only has to stay off the user's settings, library, models and keychain.
    static func testHost(environment: [String: String]) -> AppBootstrap? {
        guard TestHostSandbox.isTestHost(environment) else { return nil }
        let sandbox = TestHostSandbox.current
        return AppBootstrap(
            mode: .test,
            library: sandbox.library,
            models: sandbox.models,
            defaultsSuite: sandbox.defaultsSuite,
            sideEffects: [],
            filePicker: TestFilePicker(),
            apiKeyStore: InMemoryAPIKeyStore()
        )
    }

    var defaults: UserDefaults {
        if let defaultsOverride { return defaultsOverride }
        if let defaultsSuite, let store = UserDefaults(suiteName: defaultsSuite) { return store }
        return .standard
    }

    private static func parseKeyValueFlags(_ args: [String]) -> [String: String] {
        var out: [String: String] = [:]
        for arg in args where arg.hasPrefix("--") {
            guard let eq = arg.firstIndex(of: "=") else { continue }
            let key = String(arg[..<eq])
            let value = String(arg[arg.index(after: eq)...])
            out[key] = value
        }
        return out
    }
}
