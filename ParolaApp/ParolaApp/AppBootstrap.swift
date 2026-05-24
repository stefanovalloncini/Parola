import Foundation

struct AppBootstrap: @unchecked Sendable {
    enum Mode: Sendable { case normal, test }

    let mode: Mode
    let library: URL?
    let models: URL?
    let cacheDir: URL?
    let defaultsSuite: String?
    nonisolated(unsafe) let defaultsOverride: UserDefaults?  // UserDefaults is documented thread-safe; Foundation just hasn't marked it Sendable.
    let bridgePort: UInt16?
    let bridgeToken: String?
    let sideEffects: Set<BootstrapSideEffect>
    let filePicker: FilePicker
    let clock: any Clock<Duration>  // `any Clock<Duration>` isn't Sendable-marked, but the clocks we hand out (ContinuousClock, TestClock, ImmediateClock) are all immutable, safe-to-share instances.
    let headless: Bool

    init(
        mode: Mode,
        library: URL? = nil,
        models: URL? = nil,
        cacheDir: URL? = nil,
        defaultsSuite: String? = nil,
        defaultsOverride: UserDefaults? = nil,
        bridgePort: UInt16? = nil,
        bridgeToken: String? = nil,
        sideEffects: Set<BootstrapSideEffect>,
        filePicker: FilePicker,
        clock: any Clock<Duration> = ContinuousClock(),
        headless: Bool = false
    ) {
        self.mode = mode
        self.library = library
        self.models = models
        self.cacheDir = cacheDir
        self.defaultsSuite = defaultsSuite
        self.defaultsOverride = defaultsOverride
        self.bridgePort = bridgePort
        self.bridgeToken = bridgeToken
        self.sideEffects = sideEffects
        self.filePicker = filePicker
        self.clock = clock
        self.headless = headless
    }

    static let normal: AppBootstrap = AppBootstrap(
        mode: .normal,
        sideEffects: BootstrapSideEffect.all,
        filePicker: SystemFilePicker()
    )

    static func test(from args: [String]) -> AppBootstrap? {
        guard args.contains("--test-mode") else { return nil }
        let map = parseKeyValueFlags(args)
        return AppBootstrap(
            mode: .test,
            library: map["--library"].map { URL(fileURLWithPath: $0) },
            models: map["--models"].map { URL(fileURLWithPath: $0) },
            cacheDir: map["--cache-dir"].map { URL(fileURLWithPath: $0) },
            defaultsSuite: map["--defaults-suite"],
            defaultsOverride: nil,
            bridgePort: map["--bridge-port"].flatMap { UInt16($0) },
            bridgeToken: map["--bridge-token"],
            sideEffects: BootstrapSideEffect.testing,
            filePicker: SystemFilePicker(),
            clock: ContinuousClock(),
            headless: args.contains("--headless")
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
