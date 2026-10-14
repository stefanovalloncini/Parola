import AppKit
import CoreAudio
import Foundation
import ParolaCore

/// The apps Live Captions can listen to: running apps that have an audio process the tap can match.
@MainActor
@Observable
final class CaptionAppList {
    struct App: Identifiable, Equatable, Sendable {
        let bundleID: String
        let name: String
        let isMeetingApp: Bool
        var id: String { bundleID }
    }

    struct Running: Equatable, Sendable {
        let bundleID: String
        let name: String
    }

    private(set) var apps: [App] = []
    private var runningNow: [Running] = []

    @ObservationIgnored private let runningApps: @MainActor () -> [Running]
    @ObservationIgnored private let audioBundleIDs: @MainActor () -> [String]
    @ObservationIgnored private let ownBundleID: String?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var audioListener: AudioListener?

    init(
        observesChanges: Bool = true,
        ownBundleID: String? = Bundle.main.bundleIdentifier,
        runningApps: @escaping @MainActor () -> [Running] = CaptionAppList.liveRunningApps,
        audioBundleIDs: @escaping @MainActor () -> [String] = CaptionAppList.liveAudioBundleIDs
    ) {
        self.ownBundleID = ownBundleID
        self.runningApps = runningApps
        self.audioBundleIDs = audioBundleIDs
        refresh()
        if observesChanges { startObserving() }
    }

    isolated deinit {
        for token in observers { NSWorkspace.shared.notificationCenter.removeObserver(token) }
        audioListener?.remove()
    }

    func refresh() {
        let running = runningApps()
        if running != runningNow { runningNow = running }
        let fresh = Self.list(running: running, audioBundleIDs: audioBundleIDs(), ownBundleID: ownBundleID)
        if fresh != apps { apps = fresh }
    }

    /// Meeting apps first, then the rest by name; this app never appears.
    nonisolated static func list(running: [Running], audioBundleIDs: [String], ownBundleID: String?) -> [App] {
        var seen: Set<String> = []
        let matching = running.filter { app in
            guard app.bundleID != ownBundleID, seen.insert(app.bundleID).inserted else { return false }
            guard #available(macOS 14.2, *) else { return false }
            return audioBundleIDs.contains { ProcessTapAudioSource.matchesTarget(bundleID: $0, targets: [app.bundleID]) }
        }
        let known = MeetingDetector.knownMeetingApps
        return matching
            .map { App(bundleID: $0.bundleID, name: $0.name, isMeetingApp: known[$0.bundleID] != nil) }
            .sorted { lhs, rhs in
                if lhs.isMeetingApp != rhs.isMeetingApp { return lhs.isMeetingApp }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
    }

    struct Choice: Identifiable, Equatable {
        let setting: String
        let title: String
        let bundleID: String
        var id: String { setting }
    }

    /// The picker's app rows. A saved app that isn't running still gets one, so the picker never shows a blank selection.
    func choices(saved savedSetting: String) -> [Choice] {
        var rows = apps.map { Choice(setting: CaptionSource.app(bundleID: $0.bundleID).setting, title: $0.name, bundleID: $0.bundleID) }
        if case .app(let bundleID) = CaptionSource(setting: savedSetting), !apps.contains(where: { $0.bundleID == bundleID }) {
            let name = name(forBundleID: bundleID)
            let isOpen = runningNow.contains { $0.bundleID == bundleID }
            let title = isOpen ? String(localized: "\(name) (no audio)") : String(localized: "\(name) (not open)")
            rows.append(Choice(setting: savedSetting, title: title, bundleID: bundleID))
        }
        return rows
    }

    func name(forBundleID bundleID: String) -> String {
        if let app = apps.first(where: { $0.bundleID == bundleID }) { return app.name }
        return Self.installedName(forBundleID: bundleID) ?? bundleID
    }

    nonisolated static func installedName(forBundleID bundleID: String) -> String? {
        if let name = MeetingDetector.knownMeetingApps[bundleID] { return name }
        if let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.localizedName {
            return running
        }
        guard let url = SourceAppIcon.appURL(forBundleID: bundleID) else { return nil }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }

    // MARK: - Live readers

    static func liveRunningApps() -> [Running] {
        NSWorkspace.shared.runningApplications.compactMap { app in
            guard app.activationPolicy == .regular, let id = app.bundleIdentifier, let name = app.localizedName else { return nil }
            return Running(bundleID: id, name: name)
        }
    }

    static func liveAudioBundleIDs() -> [String] {
        guard #available(macOS 14.2, *) else { return [] }
        return ProcessTapAudioSource.audioProcessBundleIDs()
    }

    private func startObserving() {
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            })
        }
        audioListener = AudioListener { [weak self] in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }
}

/// Calls back when Core Audio's list of audio processes changes.
private final class AudioListener {
    private var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyProcessObjectList,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    private let block: AudioObjectPropertyListenerBlock

    init(onChange: @escaping @Sendable () -> Void) {
        block = { _, _ in onChange() }
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, block)
    }

    func remove() {
        AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, block)
    }
}
