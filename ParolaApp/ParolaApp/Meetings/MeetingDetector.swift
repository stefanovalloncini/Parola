import AppKit
import Foundation

@MainActor
final class MeetingDetector: ObservableObject {
    nonisolated static let knownMeetingApps: [String: String] = [
        "us.zoom.xos": "Zoom",
        "com.microsoft.teams2": "Microsoft Teams",
        "com.microsoft.teams": "Microsoft Teams",
        "com.cisco.webexmeetingsapp": "Webex",
        "com.cisco.webex.meetings": "Webex",
        "com.google.Meet": "Google Meet",
    ]

    @Published var detectedAppName: String?
    @Published var isEnabled: Bool {
        didSet { UserDefaults.standard.set(isEnabled, forKey: Self.defaultsKey) }
    }

    private let onDetected: @MainActor (String) -> Void
    private var lastFiredApp: String?
    private var lastFiredAt: Date?
    private var observerTokens: [NSObjectProtocol] = []

    private static let defaultsKey = "meetingDetectorEnabled"

    init(onDetected: @escaping @MainActor (String) -> Void) {
        self.onDetected = onDetected
        self.isEnabled = (UserDefaults.standard.object(forKey: Self.defaultsKey) as? Bool) ?? true
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

    private func fire(appName: String) {
        guard isEnabled else { return }
        if appName == lastFiredApp,
           let last = lastFiredAt,
           Date().timeIntervalSince(last) < 5 { return }
        lastFiredApp = appName
        lastFiredAt = Date()
        detectedAppName = appName
        onDetected(appName)
    }
}
