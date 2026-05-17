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

    static let dedupWindow: TimeInterval = 5

    @Published var detectedAppName: String?
    @Published var isEnabled: Bool {
        didSet { UserDefaults.standard.set(isEnabled, forKey: Self.defaultsKey) }
    }

    private let onDetected: @MainActor (String) -> Void
    private let clock: @MainActor () -> Date
    private var lastFiredApp: String?
    private var lastFiredAt: Date?
    private var observerTokens: [NSObjectProtocol] = []

    private static let defaultsKey = "meetingDetectorEnabled"

    init(
        onDetected: @escaping @MainActor (String) -> Void,
        clock: @escaping @MainActor () -> Date = { Date() }
    ) {
        self.onDetected = onDetected
        self.clock = clock
        self.isEnabled = (UserDefaults.standard.object(forKey: Self.defaultsKey) as? Bool) ?? true
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
