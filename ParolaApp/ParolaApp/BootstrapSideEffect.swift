import Foundation

enum BootstrapSideEffect: Sendable, Hashable {
    case sparkle
    case launchAtLogin
    case menuBarExtra
    case dockIconRegistration
    case appIntentsDonation
    case meetingDetector
    case watchedFolders
    case dictationHotkey
    case micHotkey
    case libraryPurgeOnLaunch
    case refreshYtDlp
    case liveCaptionsTranslateRestore
    case automationBridge
    case modelsPathSync
    case diagnosticsLog

    static let all: Set<BootstrapSideEffect> = [
        .sparkle, .launchAtLogin, .menuBarExtra, .dockIconRegistration, .appIntentsDonation,
        .meetingDetector, .watchedFolders, .dictationHotkey, .micHotkey,
        .libraryPurgeOnLaunch, .refreshYtDlp, .liveCaptionsTranslateRestore,
        .automationBridge, .modelsPathSync, .diagnosticsLog
    ]

    static let testing: Set<BootstrapSideEffect> = [.automationBridge]
}
