import AppKit
import Foundation

@Observable
@MainActor
final class MeetingDetector {
    nonisolated static let knownMeetingApps: [String: String] = [
        "us.zoom.xos": "Zoom",
        "com.microsoft.teams2": "Microsoft Teams",
        "com.microsoft.teams": "Microsoft Teams",
        "Cisco-Systems.Spark": "Webex",
        "com.cisco.webexmeetingsapp": "Webex",
        "com.cisco.webex.meetings": "Webex",
        "com.google.Meet": "Google Meet",
    ]

    static let dedupWindow: TimeInterval = 5

    var detectedAppName: String?
    var isEnabled: Bool {
        didSet { DefaultsStore.current.set(isEnabled, forKey: Self.defaultsKey) }
    }

    @ObservationIgnored private let onDetected: @MainActor (String) -> Void
    @ObservationIgnored private let clock: @MainActor () -> Date
    @ObservationIgnored private var lastFiredApp: String?
    @ObservationIgnored private var lastFiredAt: Date?
    @ObservationIgnored private var observerTokens: [NSObjectProtocol] = []

    private static let defaultsKey = "meetingDetectorEnabled"

    init(
        onDetected: @escaping @MainActor (String) -> Void,
        clock: @escaping @MainActor () -> Date = { Date() }
    ) {
        self.onDetected = onDetected
        self.clock = clock
        self.isEnabled = (DefaultsStore.current.object(forKey: Self.defaultsKey) as? Bool) ?? true
        startObserving()
    }

    isolated deinit {
        for token in observerTokens {
            NSWorkspace.shared.notificationCenter.removeObserver(token)
        }
    }

    private func startObserving() {
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didActivateApplicationNotification] {
            let token = center.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { note in
                let bundleID = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
                guard let bundleID, let display = MeetingDetector.knownMeetingApps[bundleID] else { return }
                Task { @MainActor [weak self] in
                    self?.fire(appName: display)
                }
            }
            observerTokens.append(token)
        }
        for app in NSWorkspace.shared.runningApplications {
            if let bundleID = app.bundleIdentifier,
               let display = MeetingDetector.knownMeetingApps[bundleID] {
                fire(appName: display)
                break
            }
        }
    }

    func fire(appName: String) {
        guard isEnabled else { return }
        let now = clock()
        if appName == lastFiredApp,
           let last = lastFiredAt,
           now.timeIntervalSince(last) < Self.dedupWindow { return }
        lastFiredApp = appName
        lastFiredAt = now
        detectedAppName = appName
        onDetected(appName)
    }
}
