import Foundation
import Sparkle

enum SparkleChannel: String, CaseIterable, Identifiable {
    case stable
    case rc
    case daily

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .stable: return "Stable"
        case .rc:     return "Release candidates"
        case .daily:  return "Daily builds"
        }
    }

    var description: String {
        switch self {
        case .stable: return "Production releases only. Recommended."
        case .rc:     return "Stable plus release candidates ahead of each ship."
        case .daily:  return "Every main-branch build. Expect bugs."
        }
    }

    /// Allow-list passed to Sparkle for this channel. `stable` returns an empty
    /// set, which Sparkle treats as "no channel filter, ship items with no channel attribute".
    var allowedChannels: Set<String> {
        switch self {
        case .stable: return []
        case .rc:     return ["rc"]
        case .daily:  return ["rc", "daily"]
        }
    }
}

@MainActor
final class SparkleUpdater: NSObject {
    static let shared = SparkleUpdater()

    private let controller: SPUStandardUpdaterController
    private let driver: ChannelAwareDriver

    private override init() {
        let driver = ChannelAwareDriver()
        self.driver = driver
        self.controller = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: driver,
            userDriverDelegate: nil
        )
        super.init()
        driver.attach(controller: controller)
    }

    func start() {
        guard feedURLConfigured else { return }
        controller.startUpdater()
    }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }

    var automaticallyChecks: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set { controller.updater.automaticallyChecksForUpdates = newValue }
    }

    var channel: SparkleChannel {
        get { driver.channel }
        set { driver.channel = newValue }
    }

    var feedURLConfigured: Bool {
        let bundle = Bundle.main
        guard let raw = bundle.infoDictionary?["SUFeedURL"] as? String else { return false }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        guard let key = bundle.infoDictionary?["SUPublicEDKey"] as? String else { return false }
        return !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

private final class ChannelAwareDriver: NSObject, SPUUpdaterDelegate {
    var channel: SparkleChannel = SparkleChannel(rawValue: UserDefaults.standard.string(forKey: "sparkleChannel") ?? "") ?? .stable
    weak var controller: SPUStandardUpdaterController?

    func attach(controller: SPUStandardUpdaterController) {
        self.controller = controller
    }

    func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        channel.allowedChannels
    }
}
