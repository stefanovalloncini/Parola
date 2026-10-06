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

    nonisolated static func bundleIDs(forAppName name: String) -> Set<String> {
        Set(knownMeetingApps.filter { $0.value == name }.keys)
    }

    var isEnabled: Bool {
        didSet { DefaultsStore.current.set(isEnabled, forKey: Self.defaultsKey) }
    }

    @ObservationIgnored private let onDetected: @MainActor (String) -> Void
    @ObservationIgnored private let onQuit: @MainActor (String) -> Void
    @ObservationIgnored private let clock: @MainActor () -> Date
    @ObservationIgnored private let runningApps: @MainActor () -> Set<String>
    @ObservationIgnored private var lastFiredApp: String?
    @ObservationIgnored private var lastFiredAt: Date?
    @ObservationIgnored private var snoozedApps: Set<String> = []
    @ObservationIgnored private var observerTokens: [NSObjectProtocol] = []

    private static let defaultsKey = "meetingDetectorEnabled"

    /// Re-reads the enabled flag after a settings reset or import.
    func reloadFromDefaults() {
        isEnabled = (DefaultsStore.current.object(forKey: Self.defaultsKey) as? Bool) ?? true
    }

    init(
        onDetected: @escaping @MainActor (String) -> Void,
        onQuit: @escaping @MainActor (String) -> Void = { _ in },
        clock: @escaping @MainActor () -> Date = { Date() },
        runningApps: @escaping @MainActor () -> Set<String> = { MeetingDetector.runningMeetingApps() }
    ) {
        self.onDetected = onDetected
        self.onQuit = onQuit
        self.clock = clock
        self.runningApps = runningApps
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
            let isLaunch = name == NSWorkspace.didLaunchApplicationNotification
            let token = center.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { [weak self] note in
                let bundleID = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
                guard let bundleID, let display = MeetingDetector.knownMeetingApps[bundleID] else { return }
                Task { @MainActor in
                    if isLaunch { self?.snoozedApps.remove(display) }
                    self?.fire(appName: display)
                }
            }
            observerTokens.append(token)
        }
        let quitToken = center.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            let bundleID = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
            guard let bundleID, let display = MeetingDetector.knownMeetingApps[bundleID] else { return }
            Task { @MainActor in self?.quit(appName: display) }
        }
        observerTokens.append(quitToken)
        if let display = runningApps().sorted().first { fire(appName: display) }
    }

    func fire(appName: String) {
        guard isEnabled, !snoozedApps.contains(appName) else { return }
        let now = clock()
        if appName == lastFiredApp,
           let last = lastFiredAt,
           now.timeIntervalSince(last) < Self.dedupWindow { return }
        lastFiredApp = appName
        lastFiredAt = now
        onDetected(appName)
    }

    /// Declining the prompt mutes that app until it launches again.
    func snooze(appName: String) {
        snoozedApps.insert(appName)
    }

    /// A meeting app that quit takes back what it offered, unless another copy of it still runs; launched again, it is offered again.
    func quit(appName: String) {
        guard !runningApps().contains(appName) else { return }
        if lastFiredApp == appName {
            lastFiredApp = nil
            lastFiredAt = nil
        }
        onQuit(appName)
    }

    /// The known meeting apps running now, by name — empty under the unit-test host, so no test depends on what's running on the machine.
    static func runningMeetingApps(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Set<String> {
        guard !TestHostSandbox.isTestHost(environment) else { return [] }
        return Set(NSWorkspace.shared.runningApplications.compactMap { app in
            guard !app.isTerminated, let bundleID = app.bundleIdentifier else { return nil }
            return knownMeetingApps[bundleID]
        })
    }
}
