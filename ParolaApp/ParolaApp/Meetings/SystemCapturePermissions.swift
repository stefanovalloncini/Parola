import AppKit
import CoreGraphics
import Observation
import ParolaCore

@MainActor
@Observable
final class SystemCapturePermissions {
    private(set) var screenRecordingGranted: Bool
    private(set) var systemAudioStatus: SystemAudioRecordingPermission

    @ObservationIgnored private let screenCheck: @Sendable () -> Bool
    @ObservationIgnored private let screenRequest: () -> Bool
    @ObservationIgnored private let audioCheck: @Sendable () -> SystemAudioRecordingPermission
    @ObservationIgnored private var reads = 0
    @ObservationIgnored private var settled: Bool
    @ObservationIgnored private let consentProbe: @Sendable () async -> Void
    @ObservationIgnored private let openSettingsPane: (String) -> Void
    @ObservationIgnored private var activationObserver: NSObjectProtocol?
    @ObservationIgnored private var probeTask: Task<Void, Never>?

    init(
        screenCheck: @escaping @Sendable () -> Bool = { CGPreflightScreenCaptureAccess() },
        screenRequest: @escaping () -> Bool = { CGRequestScreenCaptureAccess() },
        audioCheck: @escaping @Sendable () -> SystemAudioRecordingPermission = { .current() },
        consentProbe: @escaping @Sendable () async -> Void = {
            if #available(macOS 14.2, *) { await SystemAudioRecordingPermission.triggerConsentPrompt() }
        },
        openSettingsPane: @escaping (String) -> Void = SystemCapturePermissions.openSystemSettings,
        readsAtLaunch: Bool = true
    ) {
        self.screenCheck = screenCheck
        self.screenRequest = screenRequest
        self.audioCheck = audioCheck
        self.consentProbe = consentProbe
        self.openSettingsPane = openSettingsPane
        settled = readsAtLaunch
        screenRecordingGranted = readsAtLaunch && screenCheck()
        systemAudioStatus = readsAtLaunch ? audioCheck() : .undetermined
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
        probeTask?.cancel()
    }

    var systemAudioGranted: Bool { systemAudioStatus == .granted }

    /// The checks are TCC and WindowServer round trips, so a launch or an app activation asks off the main thread and applies the answer unless a direct `refresh()` has landed since.
    func refreshInBackground() {
        let started = reads
        let screen = screenCheck
        let audio = audioCheck
        Task { [weak self] in
            guard let answer = try? await AppModel.offMainIO(qos: .utility, { (screen(), audio()) }) else { return }
            guard let self, self.reads == started else { return }
            self.apply(screen: answer.0, audio: answer.1)
        }
    }

    func refresh() {
        apply(screen: screenCheck(), audio: audioCheck())
    }

    private func apply(screen: Bool, audio: SystemAudioRecordingPermission) {
        reads += 1
        let previousScreen = screenRecordingGranted
        let previousAudio = systemAudioStatus
        screenRecordingGranted = screen
        systemAudioStatus = audio
        guard settled else {
            settled = true
            return
        }
        // Every app activation refreshes, so only a changed answer is worth a record.
        if screenRecordingGranted != previousScreen {
            ParolaLog.notice(
                .appPermissions,
                "screen recording permission \(PermissionState(granted: screenRecordingGranted))"
            )
        }
        if systemAudioStatus != previousAudio {
            ParolaLog.notice(.appPermissions, "system audio permission \(systemAudioStatus)")
        }
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

    /// A launch without `.capturePermissionChecks`, as in test mode, never reaches TCC: nothing reads as granted and nothing is asked.
    static func forLaunch(
        sideEffects: Set<BootstrapSideEffect>,
        system: () -> SystemCapturePermissions = { SystemCapturePermissions(readsAtLaunch: false) }
    ) -> SystemCapturePermissions {
        guard sideEffects.contains(.capturePermissionChecks) else {
            return SystemCapturePermissions(
                screenCheck: { false },
                screenRequest: { false },
                audioCheck: { .undetermined },
                consentProbe: {},
                openSettingsPane: { _ in },
                readsAtLaunch: false
            )
        }
        return system()
    }

    nonisolated static func openSystemSettings(pane: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") else { return }
        NSWorkspace.shared.open(url)
    }
}
