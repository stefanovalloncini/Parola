import AVFoundation
import Foundation
import ParolaCore

/// The three answers a permission check can give, mapped in here since `AVAuthorizationStatus` must not conform to `LogSafe`.
enum PermissionState: String, LogSafe {
    case granted
    case denied
    case undetermined

    var logToken: String { rawValue }

    init(granted: Bool) {
        self = granted ? .granted : .denied
    }

    init(granted: Bool, undetermined: Bool) {
        if granted {
            self = .granted
        } else {
            self = undetermined ? .undetermined : .denied
        }
    }

    init(_ status: AVAuthorizationStatus) {
        switch status {
        case .authorized: self = .granted
        case .notDetermined: self = .undetermined
        default: self = .denied
        }
    }
}

extension RecoveryCheckpoint.Kind: LogSafe {
    var logToken: String { rawValue }
}

extension BootstrapSideEffect: LogSafe {
    var logToken: String {
        switch self {
        case .sparkle: return "sparkle"
        case .launchAtLogin: return "launchAtLogin"
        case .menuBarExtra: return "menuBarExtra"
        case .dockIconRegistration: return "dockIconRegistration"
        case .appIntentsDonation: return "appIntentsDonation"
        case .meetingDetector: return "meetingDetector"
        case .watchedFolders: return "watchedFolders"
        case .dictationHotkey: return "dictationHotkey"
        case .micHotkey: return "micHotkey"
        case .libraryPurgeOnLaunch: return "libraryPurgeOnLaunch"
        case .refreshYtDlp: return "refreshYtDlp"
        case .liveCaptionsTranslateRestore: return "liveCaptionsTranslateRestore"
        case .automationBridge: return "automationBridge"
        case .modelsPathSync: return "modelsPathSync"
        case .diagnosticsLog: return "diagnosticsLog"
        }
    }
}

/// One field-sized value for a set of tokens, sorted so two launches of the same build read the same.
struct TokenList: LogSafe {
    let logToken: String

    init<Values: Sequence>(_ values: Values) where Values.Element: LogSafe {
        let tokens = values.map(\.logToken).sorted()
        logToken = tokens.isEmpty ? "none" : tokens.joined(separator: ",")
    }
}

/// The bundle's version and build, echoed only when they look like real numbers — an Info.plist can hold anything.
struct AppVersionToken: LogSafe {
    private let short: String
    private let build: String

    init(bundle: Bundle = .main) {
        let info = bundle.infoDictionary
        short = info?["CFBundleShortVersionString"] as? String ?? ""
        build = info?["CFBundleVersion"] as? String ?? ""
    }

    var logToken: String {
        "\(Self.digits(short, dotted: true)) (\(Self.digits(build, dotted: false)))"
    }

    private static func digits(_ value: String, dotted: Bool) -> String {
        let pattern = dotted ? #"^[0-9]{1,4}(\.[0-9]{1,4}){0,3}$"# : #"^[0-9]{1,10}$"#
        return value.range(of: pattern, options: .regularExpression) != nil ? value : "unrecognized"
    }
}
