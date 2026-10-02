import AppKit
import Foundation

/// A take's controls from outside the window, as the menu bar item and the pill offer them: the calls the Stage makes.
@MainActor
enum TakeRemote {
    /// The take's light: red while it records, amber while it pauses, grey while it starts or finishes, amber once it failed.
    enum Lamp: Equatable {
        case recording
        case paused
        case waiting
        case stopped

        var tint: ThemeColor {
            switch self {
            case .recording: DS.Color.recordingFillTheme
            case .paused, .stopped: DS.theme.warningText
            case .waiting: DS.theme.textSecondary
            }
        }
    }

    nonisolated static func lamp(for take: RecordingSession) -> Lamp {
        switch take.state {
        case .recording: .recording
        case .paused: .paused
        case .failed: .stopped
        default: .waiting
        }
    }

    /// The take's time; while it arms, what it waits on: a model's download as a percentage, else "…", never a 0:00 that reads as recording.
    nonisolated static func clock(for take: RecordingSession, now: Date) -> String {
        switch take.state {
        case .arming(.preparingModel(_, let download?)): AppFormat.percent(download)
        case .arming: "…"
        default: StageClock.text(seconds: Int(take.elapsed(at: now)))
        }
    }

    /// What a take that failed out of sight says where its time was.
    nonisolated static func stoppedTitle(bundle: Bundle = .main) -> String {
        String(localized: "Take.Stopped", defaultValue: "Stopped", bundle: bundle)
    }

    /// What VoiceOver hears for a failed take, worded as its banner is: a recording that couldn't start or stopped, or only the reason once its transcription failed.
    nonisolated static func failureStatus(_ message: String, failedWhile: RecordingSession.FailedWhile?, bundle: Bundle = .main) -> String {
        switch failedWhile {
        case .starting: String(localized: "Couldn't start the recording: \(message)", bundle: bundle)
        case .transcribing: message
        case .recording, nil: String(localized: "Recording stopped: \(message)", bundle: bundle)
        }
    }

    /// Why a take the pill and the menu bar item hold as stopped ended, and what VoiceOver hears for it.
    struct Ending: Equatable {
        let reason: String
        let spoken: String
    }

    /// What it recorded ending by itself, in its notice's words, once the take stops; else its failure, worded as its banner.
    nonisolated static func ending(of take: RecordingSession, stopReason: String?, bundle: Bundle = .main) -> Ending? {
        if let stopReason, !take.isRunning { return Ending(reason: stopReason, spoken: stopReason) }
        guard case .failed(let message) = take.state else { return nil }
        return Ending(reason: message, spoken: failureStatus(message, failedWhile: take.failedWhile, bundle: bundle))
    }

    /// What needs the user's eye while a take runs, on the Stage and on the surfaces outside the window.
    struct Warning: Equatable {
        let message: String
        let symbol: String
    }

    /// Low disk space first, as it ends the take; then a Mac capture that stopped while your microphone records on; then silence.
    static func warning(for take: RecordingSession, in model: AppModel) -> Warning? {
        guard take.isRunning else { return nil }
        if model.recordingDiskSpaceLow {
            return Warning(message: String(localized: "Low disk space — recording stops automatically below 200 MB."), symbol: "internaldrive")
        }
        if model.takeMacAudioStopped, take.isCapturing {
            return Warning(message: String(localized: "Mac audio stopped"), symbol: "waveform.slash")
        }
        guard model.recordingIsSilent else { return nil }
        return Warning(
            message: StageFacts.silenceWarning(source: take.source, micTrack: model.takeMicTrackState),
            symbol: "speaker.slash.fill"
        )
    }

    /// From the count-in until Stop there is a take to stop or cancel; one finishing is already on its way to the library.
    nonisolated static func canEnd(_ take: RecordingSession?) -> Bool {
        guard let take else { return false }
        return take.isRunning && take.state != .finishing
    }

    /// Discard… is for audio already recorded; a take still arming has none, and its Stop already ends it quietly.
    nonisolated static func canDiscard(_ take: RecordingSession?) -> Bool {
        take?.isCapturing ?? false
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
        case .failed(let message): return failureStatus(message, failedWhile: take.failedWhile, bundle: bundle)
        default: return String(localized: "Recording, \(time)", bundle: bundle)
        }
    }

    static func stop(_ model: AppModel) {
        model.stopTake()
    }

    /// Acts on what the control drew: Stop ends the take; a Cancel drawn while it started leaves it alone once it records.
    static func stopOrCancel(_ model: AppModel, cancels: Bool) {
        guard !cancels || model.recording?.isArming == true else { return }
        stop(model)
    }

    /// What ends the take from outside the Stage says what it does: Cancel Recording while the take starts, as the Stage's own Cancel does.
    nonisolated static func endTitle(for take: RecordingSession?, bundle: Bundle = .main) -> String {
        take?.isArming == true
            ? String(localized: "Cancel Recording", bundle: bundle)
            : String(localized: "Stop Recording", bundle: bundle)
    }

    static func togglePause(_ model: AppModel) {
        StageControls.togglePause(model)
    }

    static func addMarker(_ model: AppModel) {
        model.addTakeMarker()
    }

    private(set) static var askingToDiscard = false

    /// Discard… asks first, one question at a time; a take that ended or changed while it stood stays. One still arming has nothing to delete, so it ends without the question.
    @discardableResult
    static func discard(_ model: AppModel, confirm: @MainActor () async -> Bool) async -> Bool {
        guard !askingToDiscard, let take = model.recording else { return false }
        if take.isArming {
            model.cancelArmingTake()
            return true
        }
        guard canDiscard(take) else { return false }
        let takeID = take.takeID
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
        return discardAlert().runModal() == .alertSecondButtonReturn
    }

    /// The same question as a sheet on the window it is asked from.
    static func askToDiscard(on window: NSWindow) async -> Bool {
        await discardAlert().beginSheetModal(for: window) == .alertSecondButtonReturn
    }

    private static func discardAlert() -> NSAlert {
        let alert = NSAlert()
        alert.messageText = String(localized: "Discard this recording?")
        alert.informativeText = String(localized: "The audio is deleted.")
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.addButton(withTitle: String(localized: "Discard")).hasDestructiveAction = true
        return alert
    }
}
