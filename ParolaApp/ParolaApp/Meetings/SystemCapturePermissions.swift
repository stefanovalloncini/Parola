import AppKit
import CoreGraphics
import Observation
import ParolaCore

@MainActor
@Observable
final class SystemCapturePermissions {
    private(set) var screenRecordingGranted: Bool
    private(set) var systemAudioStatus: SystemAudioRecordingPermission

    @ObservationIgnored private let screenCheck: () -> Bool
    @ObservationIgnored private let screenRequest: () -> Bool
    @ObservationIgnored private let audioCheck: () -> SystemAudioRecordingPermission
    @ObservationIgnored private let consentProbe: @Sendable () async -> Void
    @ObservationIgnored private let openSettingsPane: (String) -> Void
    @ObservationIgnored private var activationObserver: NSObjectProtocol?
    @ObservationIgnored private var probeTask: Task<Void, Never>?

    init(
        screenCheck: @escaping () -> Bool = { CGPreflightScreenCaptureAccess() },
        screenRequest: @escaping () -> Bool = { CGRequestScreenCaptureAccess() },
        audioCheck: @escaping () -> SystemAudioRecordingPermission = { .current() },
        consentProbe: @escaping @Sendable () async -> Void = {
            if #available(macOS 14.2, *) { await SystemAudioRecordingPermission.triggerConsentPrompt() }
        },
        openSettingsPane: @escaping (String) -> Void = SystemCapturePermissions.openSystemSettings
    ) {
        self.screenCheck = screenCheck
        self.screenRequest = screenRequest
        self.audioCheck = audioCheck
        self.consentProbe = consentProbe
        self.openSettingsPane = openSettingsPane
        screenRecordingGranted = screenCheck()
        systemAudioStatus = audioCheck()
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
        probeTask?.cancel()
    }

    var systemAudioGranted: Bool { systemAudioStatus == .granted }

    func refresh() {
        screenRecordingGranted = screenCheck()
        systemAudioStatus = audioCheck()
    }

    func requestScreenRecording() {
        if !screenRequest() {
            openSettingsPane("Privacy_ScreenCapture")
        }
        refresh()
    }

    func requestSystemAudio() {
        if systemAudioStatus == .denied {
            openSettingsPane("Privacy_AudioCapture")
            return
        }
        guard probeTask == nil else { return }
        let probe = consentProbe
        probeTask = Task { @MainActor [weak self] in
            await probe()
            guard let self else { return }
            self.probeTask = nil
            self.refresh()
        }
    }

    nonisolated private static func openSystemSettings(pane: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") else { return }
        NSWorkspace.shared.open(url)
    }
}
