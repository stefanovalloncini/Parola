import Foundation

/// What one attempt at a delivery came to.
public enum DeliveryOutcome: Sendable, Equatable {
    case delivered(DeliveryReceipt)
    case queued(attempt: Int, nextAt: Date)
    case skipped(reason: DeliverySkipReason)
}

public extension DeliveryOutcome {
    var isDelivered: Bool {
        if case .delivered = self { return true }
        return false
    }

    var receipt: DeliveryReceipt? {
        guard case .delivered(let receipt) = self else { return nil }
        return receipt
    }
}

/// Why a delivery was not attempted, or was given up on.
public enum DeliverySkipReason: Sendable, Equatable {
    case unknownDestination
    case notEnabled
    case unsupportedKind(String)
    case payloadUnavailable(String)
    case givenUp(String)
    case alreadySending(String)

    public var message: String {
        switch self {
        case .unknownDestination:
            return "That destination is no longer in Send To settings."
        case .notEnabled:
            return "That destination is switched off."
        case .unsupportedKind(let kind):
            return "This version of Parola can't send to a \(kind) destination."
        case .payloadUnavailable(let reason):
            return "Parola couldn't read the transcript to send. \(reason)"
        case .givenUp(let name):
            return "Parola stopped trying to send to \(name)."
        case .alreadySending(let name):
            return "Parola is already sending that transcript to \(name)."
        }
    }
}

/// One destination's outcome in a fan-out, with the destination it belongs to.
public struct DeliveryAttempt: Sendable, Equatable {
    public let destinationID: UUID
    public let destinationName: String
    public let outcome: DeliveryOutcome

    public init(destinationID: UUID, destinationName: String, outcome: DeliveryOutcome) {
        self.destinationID = destinationID
        self.destinationName = destinationName
        self.outcome = outcome
    }
}

/// A delivery waiting for its next attempt.
public struct QueuedDelivery: Codable, Sendable, Equatable {
    public var entryID: LibraryEntry.ID
    public var destinationID: UUID
    /// How many attempts have already been made.
    public var attempt: Int
    public var nextAttemptAt: Date

    public init(entryID: LibraryEntry.ID, destinationID: UUID, attempt: Int, nextAttemptAt: Date) {
        self.entryID = entryID
        self.destinationID = destinationID
        self.attempt = attempt
        self.nextAttemptAt = nextAttemptAt
    }
}

/// One line of what the delivery layer did, for the Send To pane and the diagnostics report.
public struct DeliveryLogEntry: Codable, Sendable, Equatable {
    public enum Event: String, Codable, Sendable {
        case delivered
        case queued
        case dropped
        case skipped
    }

    public var at: Date
    public var event: Event
    public var entryID: LibraryEntry.ID
    public var destinationID: UUID
    public var destinationName: String
    public var attempt: Int
    public var detail: String?

    public init(
        at: Date,
        event: Event,
        entryID: LibraryEntry.ID,
        destinationID: UUID,
        destinationName: String,
        attempt: Int,
        detail: String?
    ) {
        self.at = at
        self.event = event
        self.entryID = entryID
        self.destinationID = destinationID
        self.destinationName = destinationName
        self.attempt = attempt
        self.detail = detail
    }
}

/// The last hundred delivery lines, oldest first.
public struct DeliveryLog: Codable, Sendable, Equatable {
    public static let capacity = 100

    public private(set) var entries: [DeliveryLogEntry]

    public init(entries: [DeliveryLogEntry] = []) {
        self.entries = Array(entries.suffix(Self.capacity))
    }

    public mutating func append(_ entry: DeliveryLogEntry) {
        entries.append(entry)
        if entries.count > Self.capacity {
            entries.removeFirst(entries.count - Self.capacity)
        }
    }
}

/// Where the retry queue and the delivery log live between launches.
public struct DeliveryQueueStore: Sendable {
    public let directory: URL

    public init(directory: URL = DeliveryQueueStore.defaultDirectory) {
        self.directory = directory
    }

    public static var defaultDirectory: URL {
        URL.applicationSupportDirectory.appending(path: "Parola/Delivery", directoryHint: .isDirectory)
    }

    public var queueURL: URL { directory.appendingPathComponent("queue.json") }
    public var logURL: URL { directory.appendingPathComponent("log.json") }

    public func loadQueue() -> [QueuedDelivery] {
        guard FileManager.default.fileExists(atPath: queueURL.path) else { return [] }
        do {
            return try Self.decoder.decode([QueuedDelivery].self, from: try Data(contentsOf: queueURL))
        } catch {
            ParolaLog.error(.export, "delivery queue could not be read", [.error: .error(error)])
            return []
        }
    }

    public func save(queue: [QueuedDelivery]) {
        write(queue, to: queueURL)
    }

    public func loadLog() -> DeliveryLog {
        guard FileManager.default.fileExists(atPath: logURL.path) else { return DeliveryLog() }
        do {
            return try Self.decoder.decode(DeliveryLog.self, from: try Data(contentsOf: logURL))
        } catch {
            ParolaLog.error(.export, "delivery log could not be read", [.error: .error(error)])
            return DeliveryLog()
        }
    }

    public func save(log: DeliveryLog) {
        write(log, to: logURL)
    }

    private func write<T: Encodable>(_ value: T, to url: URL) {
        do {
            let data = try Self.encoder.encode(value)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        } catch {
            ParolaLog.error(.export, "delivery state could not be written", [.error: .error(error)])
        }
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

/// Runs deliveries and keeps retrying the ones that failed. The queue is on disk, so a delivery
/// outlives the launch that started it; the waiting goes through the injected clock.
public actor DeliveryEngine {
    public static let maxAttempts = 10
    /// A minute, five, half an hour, then once a day.
    public static let retryDelays: [Duration] = [.seconds(60), .seconds(300), .seconds(1800), .seconds(86_400)]

    public static func delay(forAttempt attempt: Int) -> Duration {
        let index = max(1, attempt) - 1
        return retryDelays[min(index, retryDelays.count - 1)]
    }

    private struct QueueKey: Hashable {
        let entryID: LibraryEntry.ID
        let destinationID: UUID
    }

    private let destinationsProvider: @Sendable () async -> [AnyDestination]
    private let payloadProvider: @Sendable (LibraryEntry.ID) async throws -> DeliveryPayload
    private let store: DeliveryQueueStore
    private let clock: any Clock<Duration>
    private let recordReceipt: @Sendable (DeliveryReceipt, LibraryEntry.ID) async -> Void

    private var queue: [QueuedDelivery]
    private var log: DeliveryLog
    private var timers: [QueueKey: Task<Void, Never>] = [:]
    private var inFlight: Set<QueueKey> = []

    public init(
        destinations: @escaping @Sendable () async -> [AnyDestination],
        payload: @escaping @Sendable (LibraryEntry.ID) async throws -> DeliveryPayload,
        store: DeliveryQueueStore,
        clock: any Clock<Duration>,
        recordReceipt: @escaping @Sendable (DeliveryReceipt, LibraryEntry.ID) async -> Void = { _, _ in }
    ) {
        self.destinationsProvider = destinations
        self.payloadProvider = payload
        self.store = store
        self.clock = clock
        self.recordReceipt = recordReceipt
        self.queue = store.loadQueue()
        self.log = store.loadLog()
        Task { await self.resumeQueue() }
    }

    deinit {
        for timer in timers.values { timer.cancel() }
    }

    // MARK: - Sending

    /// The one way a delivery is attempted by hand. A retry lands here too: the attempt count
    /// comes from the queue, so retrying does not start the backoff over.
    public func send(entryID: LibraryEntry.ID, to destinationID: UUID) async -> DeliveryOutcome {
        let stored = await destinationsProvider().first { $0.id == destinationID }
        guard let stored else {
            return skip(.unknownDestination, entryID: entryID, destinationID: destinationID, name: "")
        }
        guard let destination = stored.destination else {
            return skip(
                .unsupportedKind(stored.kind?.rawValue ?? "unknown"),
                entryID: entryID, destinationID: destinationID, name: stored.name
            )
        }
        guard destination.isEnabled else {
            return skip(.notEnabled, entryID: entryID, destinationID: destinationID, name: destination.name)
        }
        do {
            let payload = try await payloadProvider(entryID)
            return await attempt(payload: payload, destination: destination)
        } catch {
            if error is DeliveryPayloadError { dequeue(QueueKey(entryID: entryID, destinationID: destinationID)) }
            return skip(
                .payloadUnavailable(error.localizedDescription),
                entryID: entryID, destinationID: destinationID, name: destination.name
            )
        }
    }

    /// Every enabled auto-send destination that takes this entry's category.
    public func sendAutomatically(entryID: LibraryEntry.ID) async -> [DeliveryAttempt] {
        let candidates = await destinationsProvider()
            .compactMap(\.destination)
            .filter { $0.isEnabled && $0.autoSend }
        guard !candidates.isEmpty else { return [] }
        let payload: DeliveryPayload
        do {
            payload = try await payloadProvider(entryID)
        } catch {
            let detail = DeliverySkipReason.payloadUnavailable(error.localizedDescription).message
            for destination in candidates {
                append(.skipped, entryID: entryID, destination: destination, attempt: 0, detail: detail)
            }
            return []
        }
        var attempts: [DeliveryAttempt] = []
        for destination in candidates where destination.accepts(payload.category) {
            attempts.append(
                DeliveryAttempt(
                    destinationID: destination.id,
                    destinationName: destination.name,
                    outcome: await attempt(payload: payload, destination: destination)
                )
            )
        }
        return attempts
    }

    // MARK: - Queue

    public func pending() -> [QueuedDelivery] { queue }

    /// Stops retrying every delivery of an entry the user deleted: a trashed transcript must not
    /// reach a vault when it comes back online.
    public func cancel(entryID: LibraryEntry.ID) async {
        let keys = queue
            .filter { $0.entryID == entryID }
            .map { QueueKey(entryID: $0.entryID, destinationID: $0.destinationID) }
        guard !keys.isEmpty else { return }
        let names = Dictionary(
            await destinationsProvider().map { ($0.id, $0.name) },
            uniquingKeysWith: { first, _ in first }
        )
        for key in keys {
            let attempts = queueAttempt(key)
            dequeue(key)
            record(
                DeliveryLogEntry(
                    at: Date(), event: .dropped, entryID: key.entryID,
                    destinationID: key.destinationID, destinationName: names[key.destinationID] ?? "",
                    attempt: attempts, detail: DeliveryPayloadError.entryGone(entryID).localizedDescription
                )
            )
        }
    }

    public func recentLog() -> [DeliveryLogEntry] { log.entries }

    /// The task waiting to retry one delivery. A test takes it before it advances the clock and
    /// awaits it afterwards, so the retry is a suspension point rather than a wait on real time.
    func timerTask(for entryID: LibraryEntry.ID, destinationID: UUID) -> Task<Void, Never>? {
        timers[QueueKey(entryID: entryID, destinationID: destinationID)]
    }

    private func attempt(payload: DeliveryPayload, destination: any DeliveryDestination) async -> DeliveryOutcome {
        let key = QueueKey(entryID: payload.entryID, destinationID: destination.id)
        guard inFlight.insert(key).inserted else {
            return skip(
                .alreadySending(destination.name),
                entryID: key.entryID, destinationID: key.destinationID, name: destination.name
            )
        }
        defer { inFlight.remove(key) }
        let attemptsSoFar = queue.first { $0.entryID == key.entryID && $0.destinationID == key.destinationID }?.attempt ?? 0
        do {
            let receipt = try await destination.deliver(payload)
            dequeue(key)
            await recordReceipt(receipt, payload.entryID)
            append(
                .delivered, entryID: key.entryID, destination: destination,
                attempt: attemptsSoFar + 1, detail: receipt.location?.path
            )
            return .delivered(receipt)
        } catch {
            return failed(key, destination: destination, attempt: attemptsSoFar + 1, error: error)
        }
    }

    private func failed(
        _ key: QueueKey,
        destination: any DeliveryDestination,
        attempt: Int,
        error: any Error
    ) -> DeliveryOutcome {
        guard attempt < Self.maxAttempts else {
            dequeue(key)
            append(
                .dropped, entryID: key.entryID, destination: destination,
                attempt: attempt, detail: error.localizedDescription
            )
            return .skipped(reason: .givenUp(destination.name))
        }
        let delay = Self.delay(forAttempt: attempt)
        let nextAt = Date().addingTimeInterval(delay.wallSeconds)
        enqueue(
            QueuedDelivery(
                entryID: key.entryID, destinationID: key.destinationID,
                attempt: attempt, nextAttemptAt: nextAt
            )
        )
        append(
            .queued, entryID: key.entryID, destination: destination,
            attempt: attempt, detail: error.localizedDescription
        )
        schedule(key, after: delay)
        return .queued(attempt: attempt, nextAt: nextAt)
    }

    private func resumeQueue() {
        for item in queue {
            let key = QueueKey(entryID: item.entryID, destinationID: item.destinationID)
            schedule(key, after: .seconds(max(0, item.nextAttemptAt.timeIntervalSinceNow)))
        }
    }

    private func schedule(_ key: QueueKey, after delay: Duration) {
        timers.removeValue(forKey: key)?.cancel()
        timers[key] = Task { [weak self, clock] in
            try? await clock.sleep(for: delay, tolerance: nil)
            guard !Task.isCancelled else { return }
            await self?.runQueued(key)
        }
    }

    private func runQueued(_ key: QueueKey) async {
        timers[key] = nil
        guard queue.contains(where: { $0.entryID == key.entryID && $0.destinationID == key.destinationID }) else {
            return
        }
        let stored = await destinationsProvider().first { $0.id == key.destinationID }
        guard let destination = stored?.destination, destination.isEnabled else {
            dequeue(key)
            appendMissing(key, name: stored?.name ?? "", event: .skipped, detail: "the destination is gone or switched off")
            return
        }
        do {
            let payload = try await payloadProvider(key.entryID)
            _ = await attempt(payload: payload, destination: destination)
        } catch let error as DeliveryPayloadError {
            let attempts = queueAttempt(key)
            dequeue(key)
            append(.dropped, entryID: key.entryID, destination: destination, attempt: attempts, detail: error.localizedDescription)
        } catch {
            _ = failed(key, destination: destination, attempt: queueAttempt(key) + 1, error: error)
        }
    }

    private func queueAttempt(_ key: QueueKey) -> Int {
        queue.first { $0.entryID == key.entryID && $0.destinationID == key.destinationID }?.attempt ?? 0
    }

    private func enqueue(_ item: QueuedDelivery) {
        if let index = queue.firstIndex(where: {
            $0.entryID == item.entryID && $0.destinationID == item.destinationID
        }) {
            queue[index] = item
        } else {
            queue.append(item)
        }
        store.save(queue: queue)
    }

    private func dequeue(_ key: QueueKey) {
        timers.removeValue(forKey: key)?.cancel()
        let before = queue.count
        queue.removeAll { $0.entryID == key.entryID && $0.destinationID == key.destinationID }
        if queue.count != before { store.save(queue: queue) }
    }

    // MARK: - Log

    private func skip(
        _ reason: DeliverySkipReason,
        entryID: LibraryEntry.ID,
        destinationID: UUID,
        name: String
    ) -> DeliveryOutcome {
        appendMissing(
            QueueKey(entryID: entryID, destinationID: destinationID),
            name: name, event: .skipped, detail: reason.message
        )
        return .skipped(reason: reason)
    }

    private func append(
        _ event: DeliveryLogEntry.Event,
        entryID: LibraryEntry.ID,
        destination: any DeliveryDestination,
        attempt: Int,
        detail: String?
    ) {
        record(
            DeliveryLogEntry(
                at: Date(), event: event, entryID: entryID,
                destinationID: destination.id, destinationName: destination.name,
                attempt: attempt, detail: detail
            )
        )
    }

    private func appendMissing(
        _ key: QueueKey,
        name: String,
        event: DeliveryLogEntry.Event,
        detail: String?
    ) {
        record(
            DeliveryLogEntry(
                at: Date(), event: event, entryID: key.entryID,
                destinationID: key.destinationID, destinationName: name,
                attempt: 0, detail: detail
            )
        )
    }

    private func record(_ entry: DeliveryLogEntry) {
        log.append(entry)
        store.save(log: log)
        ParolaLog.info(.export, "delivery \(entry.event)", [.attempt: .int(entry.attempt)])
    }
}

extension Duration {
    /// Seconds as a Double, for a deadline that has to travel as a `Date`.
    var wallSeconds: Double {
        let parts = components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }
}
