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
        didSet { UserDefaults.standard.set(isEnabled, forKey: "meetingDetectorEnabled") }
    }

    private let onDetected: @MainActor (String) -> Void
    private var lastFiredAt: Date?
    private var observerTokens: [NSObjectProtocol] = []

    init(onDetected: @escaping @MainActor (String) -> Void) {
        self.onDetected = onDetected
        self.isEnabled = UserDefaults.standard.bool(forKey: "meetingDetectorEnabled")
        startObserving()
    }

    isolated deinit {
        for token in observerTokens {
            NSWorkspace.shared.notificationCenter.removeObserver(token)
        }
    }

    private func startObserving() {
        let token = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
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

    private func fire(appName: String) {
        guard isEnabled else { return }
        if let last = lastFiredAt, Date().timeIntervalSince(last) < 30 { return }
        lastFiredAt = Date()
        detectedAppName = appName
        onDetected(appName)
    }
}
