import AppKit
import ApplicationServices
import AVFoundation
import Observation

@MainActor
@Observable
final class DictationPermissions {
    private(set) var accessibilityGranted: Bool
    private(set) var microphoneAuthorized: Bool
    private(set) var microphoneUndetermined: Bool

    @ObservationIgnored var onAccessibilityGranted: (() -> Void)?

    @ObservationIgnored private let trustCheck: () -> Bool
    @ObservationIgnored private let microphoneStatus: () -> AVAuthorizationStatus
    @ObservationIgnored private let grantPollInterval: Duration
    @ObservationIgnored private var activationObserver: NSObjectProtocol?
    @ObservationIgnored private var grantPollTask: Task<Void, Never>?

    init(
        trustCheck: @escaping () -> Bool = { AXIsProcessTrusted() },
        microphoneStatus: @escaping () -> AVAuthorizationStatus = { AVCaptureDevice.authorizationStatus(for: .audio) },
        grantPollInterval: Duration = .seconds(2)
    ) {
        self.trustCheck = trustCheck
        self.microphoneStatus = microphoneStatus
        self.grantPollInterval = grantPollInterval
        accessibilityGranted = trustCheck()
        let mic = microphoneStatus()
        microphoneAuthorized = mic == .authorized
        microphoneUndetermined = mic == .notDetermined
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
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
        let interval = grantPollInterval
        grantPollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                if Task.isCancelled { return }
                guard let self else { return }
                self.refresh()
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

    func refresh() {
        let wasGranted = accessibilityGranted
        accessibilityGranted = trustCheck()
        let mic = microphoneStatus()
        microphoneAuthorized = mic == .authorized
        microphoneUndetermined = mic == .notDetermined
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
        AVCaptureDevice.requestAccess(for: .audio) { _ in
            Task { @MainActor [weak self] in self?.refresh() }
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
