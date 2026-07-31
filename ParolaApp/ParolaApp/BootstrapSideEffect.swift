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
    case modelsPathSync

    static let all: Set<BootstrapSideEffect> = [
        .sparkle, .launchAtLogin, .menuBarExtra, .dockIconRegistration, .appIntentsDonation,
        .meetingDetector, .watchedFolders, .dictationHotkey,
        .libraryPurgeOnLaunch, .refreshYtDlp, .liveCaptionsTranslateRestore,
        .automationBridge, .modelsPathSync
    ]

    static let testing: Set<BootstrapSideEffect> = [.automationBridge]
}
