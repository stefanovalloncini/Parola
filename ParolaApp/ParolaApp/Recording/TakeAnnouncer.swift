import AppKit

/// Says a line to VoiceOver, with or without a window open: posted on the app through AppKit, whose announcement carries the priority VoiceOver weighs.
@MainActor
func announce(_ text: String, priority: NSAccessibilityPriorityLevel = .medium) {
    NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested, userInfo: announcementInfo(text, priority: priority))
}

/// AppKit asks every announcement for a priority: medium waits for what VoiceOver is saying, high cuts in.
nonisolated func announcementInfo(_ text: String, priority: NSAccessibilityPriorityLevel) -> [NSAccessibility.NotificationUserInfoKey: Any] {
    [.announcement: text, .priority: priority.rawValue]
}

/// Tells VoiceOver what a take does that no focus change shows: capture starting, a pause or a resume from anywhere, a failure, where a saved take went; and every notice or toast as it appears.
@MainActor
final class TakeAnnouncer {
    /// The part of the model the announcements follow.
    struct Moment: Equatable {
        enum Take: Equatable {
            case arming
            case recording
            case paused
            case windingDown
            case failed(String, RecordingSession.FailedWhile?)
            case over
        }

        var takeID: Int?
        var take: Take?
        var saved: TakeSavedNotice?
        var notice: ExportNotice?
        var arrival: ArrivalNotice?
        var delivery: DeliveryNotice?
    }

    struct Line: Equatable {
        let text: String
        /// A failure cuts in over whatever VoiceOver is saying, so it isn't lost; the rest wait their turn.
        var priority: NSAccessibilityPriorityLevel = .medium
    }

    private weak var model: AppModel?
    private let speak: @MainActor (Line) -> Void
    private var last = Moment()

    init(speak: @escaping @MainActor (Line) -> Void = { announce($0.text, priority: $0.priority) }) {
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
            take: model.recording.map { kind(of: $0) },
            saved: model.takeSavedNotice,
            notice: model.exportNotice,
            arrival: model.arrivalNotice,
            delivery: model.deliveryNotice
        )
    }

    nonisolated static func kind(of take: RecordingSession) -> Moment.Take {
        switch take.state {
        case .arming: .arming
        case .recording: .recording
        case .paused: .paused
        case .finishing, .transcribing: .windingDown
        case .failed(let message): .failed(message, take.failedWhile)
        case .done: .over
        }
    }

    /// A failure is said as its banner says it. A notice about that same failure isn't said twice.
    nonisolated static func lines(from old: Moment, to new: Moment, bundle: Bundle = .main) -> [Line] {
        var lines: [Line] = []
        let before = old.takeID == new.takeID ? old.take : nil
        switch new.take {
        case .recording where before != .recording:
            lines.append(Line(text: String(localized: "Recording", bundle: bundle)))
        case .paused where before != .paused:
            lines.append(Line(text: String(localized: "Paused", bundle: bundle)))
        case .failed(let message, let failedWhile) where !isFailure(before):
            lines.append(Line(text: TakeRemote.failureStatus(message, failedWhile: failedWhile, bundle: bundle), priority: .high))
        default:
            break
        }
        if let saved = new.saved, saved.id != old.saved?.id {
            lines.append(Line(text: TakeSavedToast.message(category: saved.category, bundle: bundle)))
        }
        if let notice = new.notice, notice.id != old.notice?.id {
            let saysTheTakeFailure = notice.takeID != nil && notice.takeID == new.takeID && isFailure(new.take)
            if !saysTheTakeFailure { lines.append(Line(text: notice.message, priority: notice.tone == .failure ? .high : .medium)) }
        }
        // A running file is progress, not news: its landing or its failure is said.
        if let arrival = new.arrival, arrival.id != old.arrival?.id, arrival.state != .running {
            let text = [arrival.title(bundle: bundle), arrival.reason].compactMap { $0 }.joined(separator: ". ")
            lines.append(Line(text: text, priority: arrival.reason == nil ? .medium : .high))
        }
        if let delivery = new.delivery, delivery != old.delivery {
            let failed = if case .failed = delivery.state { true } else { false }
            lines.append(Line(text: DeliveryToast.message(for: delivery, bundle: bundle), priority: failed ? .high : .medium))
        }
        return lines
    }

    private nonisolated static func isFailure(_ take: Moment.Take?) -> Bool {
        if case .failed = take { return true }
        return false
    }
}
