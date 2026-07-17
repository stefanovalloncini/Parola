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
    @ObservationIgnored private var activationObserver: NSObjectProtocol?

    init(
        trustCheck: @escaping () -> Bool = { AXIsProcessTrusted() },
        microphoneStatus: @escaping () -> AVAuthorizationStatus = { AVCaptureDevice.authorizationStatus(for: .audio) }
    ) {
        self.trustCheck = trustCheck
        self.microphoneStatus = microphoneStatus
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
