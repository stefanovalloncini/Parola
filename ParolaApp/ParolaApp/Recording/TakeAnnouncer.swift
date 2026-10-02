import AppKit
import SwiftUI

/// Says a line to VoiceOver, with or without a window open.
@MainActor
func announce(_ text: String) {
    AccessibilityNotification.Announcement(text).post()
}

/// Tells VoiceOver what a take does that no focus change shows: capture starting, a pause or a resume from anywhere, a failure, where a saved take went, and a notice.
@MainActor
final class TakeAnnouncer {
    /// The part of the model the announcements follow.
    struct Moment: Equatable {
        enum Take: Equatable {
            case arming
            case recording
            case paused
            case windingDown
            case failed(String)
            case over
        }

        var takeID: Int?
        var take: Take?
        var saved: TakeSavedNotice?
        var notice: ExportNotice?
    }

    private weak var model: AppModel?
    private let speak: @MainActor (String) -> Void
    private var last = Moment()

    init(speak: @escaping @MainActor (String) -> Void = announce) {
        self.speak = speak
    }

    /// What is already up when Parola binds goes unsaid; only what changes after is announced.
    func bind(_ model: AppModel) {
        self.model = model
        last = Self.moment(of: model)
        observe()
    }

    private func observe() {
        guard let model else { return }
        withObservationTracking {
            let now = Self.moment(of: model)
            for line in Self.lines(from: last, to: now) { speak(line) }
            last = now
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.observe() }
        }
    }

    static func moment(of model: AppModel) -> Moment {
        Moment(
            takeID: model.recording?.takeID,
            take: model.recording.map { kind(of: $0.state) },
            saved: model.takeSavedNotice,
            notice: model.exportNotice
        )
    }

    nonisolated static func kind(of state: RecordingSession.State) -> Moment.Take {
        switch state {
        case .arming: .arming
        case .recording: .recording
        case .paused: .paused
        case .finishing, .transcribing: .windingDown
        case .failed(let message): .failed(message)
        case .done: .over
        }
    }

    /// A failure after Stop speaks for itself; one during the take says the recording stopped. A notice about that same failure isn't said twice.
    nonisolated static func lines(from old: Moment, to new: Moment, bundle: Bundle = .main) -> [String] {
        var lines: [String] = []
        let before = old.takeID == new.takeID ? old.take : nil
        switch new.take {
        case .recording where before != .recording:
            lines.append(String(localized: "Recording", bundle: bundle))
        case .paused where before != .paused:
            lines.append(String(localized: "Paused", bundle: bundle))
        case .failed(let message) where !isFailure(before):
            lines.append(before == .windingDown ? message : TakeRemote.stoppedStatus(message, bundle: bundle))
        default:
            break
        }
        if let saved = new.saved, saved.id != old.saved?.id {
            lines.append(TakeSavedToast.message(category: saved.category, bundle: bundle))
        }
        if let notice = new.notice, notice.id != old.notice?.id, notice.tone != .success {
            let saysTheTakeFailure = notice.takeID != nil && notice.takeID == new.takeID && isFailure(new.take)
            if !saysTheTakeFailure { lines.append(notice.message) }
        }
        return lines
    }

    private nonisolated static func isFailure(_ take: Moment.Take?) -> Bool {
        if case .failed = take { return true }
        return false
    }
}
