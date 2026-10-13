import AppKit
import ApplicationServices
import AVFoundation
import Observation
import ParolaCore

@MainActor
@Observable
final class DictationPermissions {
    private(set) var accessibilityGranted: Bool
    private(set) var microphoneAuthorized: Bool
    private(set) var microphoneUndetermined: Bool

    @ObservationIgnored var onAccessibilityGranted: (() -> Void)?

    @ObservationIgnored private let trustCheck: @Sendable () -> Bool
    @ObservationIgnored private let microphoneStatus: @Sendable () -> AVAuthorizationStatus
    @ObservationIgnored private var reads = 0
    @ObservationIgnored private var settled: Bool
    @ObservationIgnored private let grantPollInterval: Duration
    @ObservationIgnored private let grantPollFastWindow: Duration
    @ObservationIgnored private let grantPollSlowInterval: Duration
    @ObservationIgnored private let grantPollSleep: @Sendable (Duration) async -> Void
    @ObservationIgnored private var activationObserver: NSObjectProtocol?
    @ObservationIgnored private var grantPollTask: Task<Void, Never>?

    init(
        trustCheck: @escaping @Sendable () -> Bool = { AXIsProcessTrusted() },
        microphoneStatus: @escaping @Sendable () -> AVAuthorizationStatus = { AVCaptureDevice.authorizationStatus(for: .audio) },
        grantPollInterval: Duration = .seconds(2),
        grantPollFastWindow: Duration = .seconds(120),
        grantPollSlowInterval: Duration = .seconds(15),
        grantPollSleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) },
        readsAtLaunch: Bool = true
    ) {
        self.trustCheck = trustCheck
        self.microphoneStatus = microphoneStatus
        self.grantPollInterval = grantPollInterval
        self.grantPollFastWindow = grantPollFastWindow
        self.grantPollSlowInterval = grantPollSlowInterval
        self.grantPollSleep = grantPollSleep
        settled = readsAtLaunch
        let mic = readsAtLaunch ? microphoneStatus() : .notDetermined
        accessibilityGranted = readsAtLaunch && trustCheck()
        microphoneAuthorized = mic == .authorized
        microphoneUndetermined = readsAtLaunch && mic == .notDetermined
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshInBackground() }
        }
        if !readsAtLaunch { refreshInBackground() }
    }

    isolated deinit {
        if let activationObserver {
            NotificationCenter.default.removeObserver(activationObserver)
        }
        grantPollTask?.cancel()
    }

    /// The didBecomeActive refresh never fires when the user grants Accessibility in
    /// System Settings without ever clicking a Parola window; polling closes that gap
    /// so the armed-but-dead hotkey comes alive without an app activation.
    func beginWatchingForGrant() {
        guard grantPollTask == nil, !accessibilityGranted else { return }
        let fast = grantPollInterval, window = grantPollFastWindow, slow = grantPollSlowInterval
        let sleep = grantPollSleep
        grantPollTask = Task { @MainActor [weak self] in
            var elapsed = Duration.zero
            while !Task.isCancelled {
                let interval = elapsed < window ? fast : slow
                await sleep(interval)
                elapsed += interval
                if Task.isCancelled { return }
                guard let self else { return }
                await self.readInBackground(since: self.reads)
                if Task.isCancelled { return }
                if self.accessibilityGranted {
                    self.grantPollTask = nil
                    return
                }
            }
        }
    }

    func endWatchingForGrant() {
        grantPollTask?.cancel()
        grantPollTask = nil
    }

    /// The checks are TCC round trips, so a launch or an app activation asks off the main thread and applies the answer unless a direct `refresh()` has landed since.
    func refreshInBackground() {
        let started = reads
        Task { [weak self] in await self?.readInBackground(since: started) }
    }

    private func readInBackground(since started: Int) async {
        let trust = trustCheck
        let status = microphoneStatus
        guard let answer = try? await AppModel.offMainIO(qos: .utility, { (trust(), status()) }) else { return }
        guard reads == started else { return }
        apply(trusted: answer.0, microphone: answer.1)
    }

    func refresh() {
        apply(trusted: trustCheck(), microphone: microphoneStatus())
    }

    private func apply(trusted: Bool, microphone mic: AVAuthorizationStatus) {
        reads += 1
        let wasGranted = accessibilityGranted
        let previousMicrophone = PermissionState(
            granted: microphoneAuthorized, undetermined: microphoneUndetermined
        )
        accessibilityGranted = trusted
        microphoneAuthorized = mic == .authorized
        microphoneUndetermined = mic == .notDetermined
        guard settled else {
            settled = true
            return
        }
        // Every app activation refreshes, so only a changed answer is worth a record.
        if accessibilityGranted != wasGranted {
            ParolaLog.notice(
                .appPermissions,
                "accessibility permission \(PermissionState(granted: accessibilityGranted))"
            )
        }
        if PermissionState(mic) != previousMicrophone {
            ParolaLog.notice(.appPermissions, "microphone permission \(PermissionState(mic))")
        }
        if !wasGranted, accessibilityGranted {
            onAccessibilityGranted?()
        }
    }

    func promptForAccessibility() {
        // kAXTrustedCheckOptionPrompt's header omits `const`, so referencing the symbol trips Swift 6 strict concurrency; the key name is ABI-stable, so it's inlined instead.
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        refresh()
    }

    func requestMicrophone() {
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func openAccessibilitySettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    func openMicrophoneSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
    }

    private func open(_ urlString: String) {
        guard let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }
}
