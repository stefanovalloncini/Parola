import AppKit
import Foundation

/// A take's controls from outside the window, as the menu bar item and the pill offer them: the calls the Stage makes.
@MainActor
enum TakeRemote {
    /// The take's light: red while it records, amber while it pauses, grey while it starts or finishes.
    enum Lamp: Equatable {
        case recording
        case paused
        case waiting

        var tint: ThemeColor {
            switch self {
            case .recording: DS.Color.recordingFillTheme
            case .paused: DS.theme.warningText
            case .waiting: DS.theme.textSecondary
            }
        }
    }

    nonisolated static func lamp(for take: RecordingSession) -> Lamp {
        switch take.state {
        case .recording: .recording
        case .paused: .paused
        default: .waiting
        }
    }

    /// What VoiceOver reads for the take: what it is doing, then its time in words.
    nonisolated static func spokenStatus(
        for take: RecordingSession, at now: Date, bundle: Bundle = .main, locale: Locale = AppFormat.locale
    ) -> String {
        let time = AppFormat.spokenDuration(seconds: Int(take.elapsed(at: now)), locale: locale)
        switch take.state {
        case .arming: return String(localized: "Getting ready to record", bundle: bundle)
        case .paused: return String(localized: "Paused, \(time)", bundle: bundle)
        case .finishing: return String(localized: "Finishing, \(time)", bundle: bundle)
        default: return String(localized: "Recording, \(time)", bundle: bundle)
        }
    }

    /// A count-in has nothing to stop yet, so Stop ends it the way the count-in's own Cancel does.
    static func stop(_ model: AppModel) {
        if model.recordingCountdown != nil {
            model.cancelRecordingCountdown()
        } else {
            model.stopRecordingAndTranscribe()
        }
    }

    static func togglePause(_ model: AppModel) {
        StageControls.togglePause(model)
    }

    static func addMarker(_ model: AppModel) {
        model.addTakeMarker()
    }

    private(set) static var askingToDiscard = false

    /// Discard… asks first, one question at a time; a take that ended or changed while it stood stays.
    @discardableResult
    static func discard(_ model: AppModel, confirm: @MainActor () async -> Bool) async -> Bool {
        guard !askingToDiscard, let takeID = model.recording?.takeID else { return false }
        askingToDiscard = true
        defer { askingToDiscard = false }
        let confirmed = await confirm()
        guard confirmed else { return false }
        return await StageControls.discard(takeID, model: model)
    }

    /// The Stage comes up first, so a window opening again opens on the take.
    static func showParola(_ model: AppModel, bringForward: () -> Void) {
        model.showStage()
        bringForward()
    }

    /// The Stage's Discard question; Return keeps the take, so only a deliberate click deletes it.
    static func askToDiscard() -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = String(localized: "Discard this recording?")
        alert.informativeText = String(localized: "The audio is deleted.")
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.addButton(withTitle: String(localized: "Discard")).hasDestructiveAction = true
        return alert.runModal() == .alertSecondButtonReturn
    }
}
