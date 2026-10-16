import AppKit
import Foundation

/// The toasts under the page as `getState` reports them; a button's id names its toast, so a press never reaches a newer one.
extension ParolaAutomationServer {
    enum ToastButton: String {
        case summarize, copy, open, openBatch, stop, retry, reveal, dismiss
    }

    static func toastActionID(_ toastID: UUID, _ button: ToastButton) -> String {
        "\(toastID.uuidString).\(button.rawValue)"
    }

    /// The saved take's toast draws Summarize only while a summary can be written.
    static func takeSavedButtons(_ model: AppModel) -> [ToastButton] {
        TakeSavedToast.offersSummary(model) ? [.summarize, .copy, .dismiss] : [.copy, .dismiss]
    }

    static func arrivalButtons(_ notice: ArrivalNotice) -> [ToastButton] {
        switch notice.state {
        case .saved: [.open, .dismiss]
        case .queued: [.openBatch, .dismiss]
        case .exported: [.dismiss]
        case .running: [.stop, .dismiss]
        case .paused, .unsaved: [.retry, .dismiss]
        case .failed: [.retry, .reveal, .dismiss]
        }
    }

    /// The window draws the saved take's toast only under that take's transcript, so it is null anywhere else.
    static func takeSavedState(_ model: AppModel) -> AutomationValue {
        guard let notice = model.takeSavedNotice, model.takeSavedToastIsOnItsTake else { return .null }
        return .object([
            "title": .string(TakeSavedToast.message(title: notice.title, category: notice.category)),
            "category": .string(notice.category.rawValue),
            "entryID": .string(notice.entryID),
            "actions": toastActions(notice.id, takeSavedButtons(model)),
        ])
    }

    /// The toast shows a landed or failed file over one still running, as the window does.
    static func arrivalNoticeState(_ model: AppModel) -> AutomationValue {
        guard let notice = model.arrivalNotice ?? model.runningArrivalNotice else { return .null }
        var entryID: AutomationValue = .null
        if case .saved(let id) = notice.state { entryID = .string(id) }
        return .object([
            "title": .string(notice.title()),
            "state": .string(arrivalStateName(notice.state)),
            "origin": .string(arrivalOriginName(notice.origin)),
            "entryID": entryID,
            "reason": notice.reason.map { .string($0) } ?? .null,
            "actions": toastActions(notice.id, arrivalButtons(notice)),
        ])
    }

    /// Presses a toast's button the way a click does; Copy fills a pasteboard of the bridge's own, which never touches the clipboard.
    static func pressToastButton(_ actionID: String, model: AppModel) async -> (pressed: Bool, copied: String?) {
        if let saved = model.takeSavedNotice, model.takeSavedToastIsOnItsTake,
           let button = takeSavedButtons(model).first(where: { toastActionID(saved.id, $0) == actionID }) {
            switch button {
            case .summarize:
                model.summarizeSavedTake(saved.entryID)
            case .copy:
                let pasteboard = NSPasteboard.withUniqueName()
                defer { pasteboard.releaseGlobally() }
                await model.copySavedTake(saved.entryID, to: pasteboard)
                return (true, pasteboard.string(forType: .string))
            case .dismiss:
                model.dismissTakeSaved()
            case .open, .openBatch, .stop, .retry, .reveal:
                return (false, nil)
            }
            return (true, nil)
        }
        guard let shown = model.arrivalNotice ?? model.runningArrivalNotice,
              let button = arrivalButtons(shown).first(where: { toastActionID(shown.id, $0) == actionID }) else {
            return (false, nil)
        }
        switch button {
        case .open: model.openArrivalNotice()
        case .openBatch: model.openBatchFromNotice()
        case .stop: model.stopBackgroundArrival()
        case .retry: model.retryArrivalNotice()
        case .reveal: model.revealFailedArrival()
        case .dismiss: if shown.state == .running { model.hideRunningArrival() } else { model.dismissArrivalNotice() }
        case .summarize, .copy: return (false, nil)
        }
        return (true, nil)
    }

    private static func toastActions(_ toastID: UUID, _ buttons: [ToastButton]) -> AutomationValue {
        .array(buttons.map { .object(["id": .string(toastActionID(toastID, $0)), "title": .string(buttonTitle($0))]) })
    }

    private static func buttonTitle(_ button: ToastButton) -> String {
        switch button {
        case .summarize: String(localized: "Summarize")
        case .copy: String(localized: "Copy")
        case .open: String(localized: "Open")
        case .openBatch: String(localized: "Open Batch")
        case .stop: String(localized: "Stop")
        case .retry: String(localized: "Retry")
        case .reveal: String(localized: "Reveal")
        case .dismiss: String(localized: "Dismiss")
        }
    }

    private static func arrivalStateName(_ state: ArrivalNotice.State) -> String {
        switch state {
        case .running: "running"
        case .saved: "saved"
        case .failed: "failed"
        case .paused: "paused"
        case .unsaved: "unsaved"
        case .queued: "queued"
        case .exported: "exported"
        }
    }

    private static func arrivalOriginName(_ origin: ArrivalNotice.Origin) -> String {
        switch origin {
        case .watchedFolder: "watchedFolder"
        case .take: "take"
        case .run: "run"
        }
    }
}
