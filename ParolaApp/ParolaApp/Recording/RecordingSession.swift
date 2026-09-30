import Foundation
import ParolaCore

struct RecordingSession: Equatable, Sendable {
    enum Arming: Equatable, Sendable {
        case countIn(remaining: Int)
        case startingCapture
        case preparingModel(name: String, download: Double?)
    }

    enum State: Equatable, Sendable {
        case arming(Arming)
        case recording
        case paused(since: Date)
        case finishing
        case transcribing(progress: Double?)
        case done(entryID: String?)
        case failed(message: String)
    }

    private static let markerDedupeWindow: TimeInterval = 1

    let takeID: Int
    let source: AppModel.RecordSource
    var category: EntryCategory
    var title: String
    var device: String?
    var isStreaming: Bool
    var audioURL: URL?
    private(set) var state: State
    private(set) var startedAt: Date?
    private(set) var pausedTotal: TimeInterval
    private(set) var endedElapsed: TimeInterval?
    private(set) var markers: [TimeInterval]
    private(set) var pauses: [TimeInterval]

    init(takeID: Int, source: AppModel.RecordSource, category: EntryCategory, title: String, isStreaming: Bool, arming: Arming) {
        self.takeID = takeID
        self.source = source
        self.category = category
        self.title = title
        self.device = nil
        self.isStreaming = isStreaming
        self.audioURL = nil
        self.state = .arming(arming)
        self.startedAt = nil
        self.pausedTotal = 0
        self.endedElapsed = nil
        self.markers = []
        self.pauses = []
    }

    var isArming: Bool {
        if case .arming = state { return true }
        return false
    }

    var isPaused: Bool {
        if case .paused = state { return true }
        return false
    }

    var isCapturing: Bool {
        state == .recording || isPaused
    }

    var isRunning: Bool {
        isArming || state == .recording || isPaused || state == .finishing
    }

    var isOver: Bool {
        switch state {
        case .done, .failed: return true
        default: return false
        }
    }

    func elapsed(at now: Date) -> TimeInterval {
        if let endedElapsed { return endedElapsed }
        guard let startedAt else { return 0 }
        let runningPause: TimeInterval
        if case .paused(let since) = state {
            runningPause = max(0, now.timeIntervalSince(since))
        } else {
            runningPause = 0
        }
        return max(0, now.timeIntervalSince(startedAt) - pausedTotal - runningPause)
    }

    @discardableResult
    mutating func arm(_ arming: Arming) -> Bool {
        guard isArming else { return false }
        state = .arming(arming)
        return true
    }

    @discardableResult
    mutating func markCapturing(at date: Date) -> Bool {
        guard isArming else { return false }
        startedAt = date
        state = .recording
        return true
    }

    @discardableResult
    mutating func pause(at date: Date) -> Bool {
        guard state == .recording else { return false }
        pauses.append(elapsed(at: date))
        state = .paused(since: date)
        return true
    }

    @discardableResult
    mutating func resume(at date: Date) -> Bool {
        guard case .paused(let since) = state else { return false }
        pausedTotal += date.timeIntervalSince(since)
        state = .recording
        return true
    }

    @discardableResult
    mutating func addMarker(at date: Date) -> TimeInterval? {
        guard state == .recording || isPaused else { return nil }
        let mark = elapsed(at: date)
        if let last = markers.last, abs(mark - last) < Self.markerDedupeWindow { return nil }
        markers.append(mark)
        return mark
    }

    @discardableResult
    mutating func finish(at date: Date) -> Bool {
        guard state == .recording || isPaused else { return false }
        endedElapsed = elapsed(at: date)
        state = .finishing
        return true
    }

    @discardableResult
    mutating func transcribing(progress: Double?) -> Bool {
        switch state {
        case .finishing, .transcribing:
            state = .transcribing(progress: progress)
            return true
        default:
            return false
        }
    }

    mutating func land(entryID: String?, at date: Date = Date()) {
        if case .failed = state { return }
        if isCapturing { endedElapsed = elapsed(at: date) }
        state = .done(entryID: entryID)
    }

    mutating func fail(_ message: String, at date: Date = Date()) {
        if case .done = state { return }
        if isCapturing { endedElapsed = elapsed(at: date) }
        state = .failed(message: message)
    }
}
