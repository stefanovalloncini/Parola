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
    case libraryPurgeOnLaunch
    case refreshYtDlp
    case liveCaptionsTranslateRestore
    case automationBridge

    static let all: Set<BootstrapSideEffect> = [
        .sparkle, .launchAtLogin, .menuBarExtra, .dockIconRegistration, .appIntentsDonation,
        .meetingDetector, .watchedFolders, .dictationHotkey,
        .libraryPurgeOnLaunch, .refreshYtDlp, .liveCaptionsTranslateRestore,
        .automationBridge
    ]

    static let testing: Set<BootstrapSideEffect> = [.automationBridge]
}
