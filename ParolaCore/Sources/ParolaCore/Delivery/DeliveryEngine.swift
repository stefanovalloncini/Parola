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
    /// The destination refused the delivery for a reason sending again cannot fix.
    case rejected(String, DeliveryError)

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
        case .rejected(_, let error):
            return error.localizedDescription
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
    /// How many checks in a row found the destination out of reach. These count no attempt, and a
    /// delivery with any is one that a fixed destination or a mounted drive brings forward.
    public var unreachableChecks: Int
    /// What the destination asked to be handed back on the next attempt, such as the page a failed send had begun.
    public var resume: String?

    public var isWaitingForDestination: Bool { unreachableChecks > 0 }

    public init(entryID: LibraryEntry.ID, destinationID: UUID, attempt: Int, nextAttemptAt: Date, unreachableChecks: Int = 0, resume: String? = nil) {
        self.entryID = entryID
        self.destinationID = destinationID
        self.attempt = attempt
        self.nextAttemptAt = nextAttemptAt
        self.unreachableChecks = unreachableChecks
        self.resume = resume
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        entryID = try c.decode(LibraryEntry.ID.self, forKey: .entryID)
        destinationID = try c.decode(UUID.self, forKey: .destinationID)
        attempt = try c.decode(Int.self, forKey: .attempt)
        nextAttemptAt = try c.decode(Date.self, forKey: .nextAttemptAt)
        unreachableChecks = try c.decodeIfPresent(Int.self, forKey: .unreachableChecks) ?? 0
        resume = try c.decodeIfPresent(String.self, forKey: .resume)
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
    /// A destination out of reach this many checks in a row, the last ones a day apart, is given up on.
    public static let maxUnreachableChecks = 30
    /// A minute, five, half an hour, then once a day.
    public static let retryDelays: [Duration] = [.seconds(60), .seconds(300), .seconds(1800), .seconds(86_400)]
    /// The gap between retries that come due at once: at launch, or when a destination is fixed.
    public static let catchUpSpacing: Duration = .seconds(2)

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
    private var cancelledInFlight: Set<QueueKey> = []

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
        let key = QueueKey(entryID: entryID, destinationID: destinationID)
        do {
            try await destination.checkReachable()
        } catch {
            guard !inFlight.contains(key) else {
                return skip(
                    .alreadySending(destination.name),
                    entryID: entryID, destinationID: destinationID, name: destination.name
                )
            }
            return waitForDestination(key, destination: destination, error: error)
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

    /// Every enabled auto-send destination that takes this entry's category. The destinations run at the
    /// same time, so a slow one never holds up the others; `progress` hears each outcome as it lands, and
    /// the result is in the destinations' order.
    public func sendAutomatically(
        entryID: LibraryEntry.ID,
        progress: @escaping @Sendable (DeliveryAttempt) async -> Void = { _ in }
    ) async -> [DeliveryAttempt] {
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
        let accepted = candidates.filter { $0.accepts(payload.category) }
        var attempts: [(Int, DeliveryAttempt)] = []
        await withTaskGroup(of: (Int, DeliveryAttempt).self) { group in
            for (index, destination) in accepted.enumerated() {
                group.addTask {
                    let outcome = await self.attempt(payload: payload, destination: destination)
                    let attempt = DeliveryAttempt(
                        destinationID: destination.id, destinationName: destination.name, outcome: outcome
                    )
                    await progress(attempt)
                    return (index, attempt)
                }
            }
            for await result in group { attempts.append(result) }
        }
        return attempts.sorted { $0.0 < $1.0 }.map(\.1)
    }

    // MARK: - Queue

    public func pending() -> [QueuedDelivery] { queue }

    /// Stops retrying every delivery of an entry the user deleted: a trashed transcript must not
    /// reach a vault when it comes back online.
    public func cancel(entryID: LibraryEntry.ID) async {
        for key in inFlight where key.entryID == entryID { cancelledInFlight.insert(key) }
        guard queue.contains(where: { $0.entryID == entryID }) else { return }
        // Names first: a retry that runs during this await drops its own item, and the keys read after it leave that one out.
        let names = Dictionary(
            await destinationsProvider().map { ($0.id, $0.name) },
            uniquingKeysWith: { first, _ in first }
        )
        let keys = queue
            .filter { $0.entryID == entryID }
            .map { QueueKey(entryID: $0.entryID, destinationID: $0.destinationID) }
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

    /// Brings every queued delivery for this destination forward to now, spaced out, once the destination
    /// answers its reachability check: the user just fixed its folder, or its drive came back. An
    /// unreachable destination keeps its schedule, and no attempt is counted.
    public func retryNow(destinationID: UUID) async {
        guard queue.contains(where: { $0.destinationID == destinationID }),
              let destination = await destinationsProvider().first(where: { $0.id == destinationID })?.destination,
              destination.isEnabled,
              (try? await destination.checkReachable()) != nil
        else { return }
        let keys = queue
            .filter { $0.destinationID == destinationID && $0.isWaitingForDestination }
            .map { QueueKey(entryID: $0.entryID, destinationID: $0.destinationID) }
        for (index, key) in keys.enumerated() {
            schedule(key, after: Self.catchUpSpacing * index)
        }
    }

    /// `retryNow(destinationID:)` for every destination with something queued, as when a volume mounts.
    public func retryNow() async {
        var seen = Set<UUID>()
        let destinationIDs = queue.map(\.destinationID).filter { seen.insert($0).inserted }
        for destinationID in destinationIDs {
            await retryNow(destinationID: destinationID)
        }
    }

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
        defer {
            inFlight.remove(key)
            cancelledInFlight.remove(key)
        }
        let queued = queue.first { $0.entryID == key.entryID && $0.destinationID == key.destinationID }
        let attemptsSoFar = queued?.attempt ?? 0
        do {
            let receipt = try await destination.deliver(payload, resume: queued?.resume)
            dequeue(key)
            await recordReceipt(receipt, payload.entryID)
            append(
                .delivered, entryID: key.entryID, destination: destination,
                attempt: attemptsSoFar + 1, detail: receipt.location?.path
            )
            return .delivered(receipt)
        } catch {
            if cancelledInFlight.contains(key) {
                dequeue(key)
                let reason = DeliveryPayloadError.entryGone(key.entryID).localizedDescription
                append(.dropped, entryID: key.entryID, destination: destination, attempt: attemptsSoFar + 1, detail: reason)
                return .skipped(reason: .payloadUnavailable(reason))
            }
            return failed(key, destination: destination, attempt: attemptsSoFar + 1, error: error)
        }
    }

    private func failed(
        _ key: QueueKey,
        destination: any DeliveryDestination,
        attempt: Int,
        error: any Error
    ) -> DeliveryOutcome {
        if case DeliveryError.vaultUnavailable = error {
            return waitForDestination(key, destination: destination, error: error)
        }
        let deliveryError = error as? DeliveryError
        if let deliveryError, deliveryError.isPermanent {
            dequeue(key)
            append(
                .dropped, entryID: key.entryID, destination: destination,
                attempt: attempt, detail: error.localizedDescription
            )
            return .skipped(reason: .rejected(destination.name, deliveryError))
        }
        guard attempt < Self.maxAttempts else {
            dequeue(key)
            append(
                .dropped, entryID: key.entryID, destination: destination,
                attempt: attempt, detail: error.localizedDescription
            )
            return .skipped(reason: .givenUp(destination.name))
        }
        let resume = deliveryError?.resumeToken ?? queue.first {
            $0.entryID == key.entryID && $0.destinationID == key.destinationID
        }?.resume
        let delay = Self.delay(forAttempt: attempt)
        let nextAt = Date().addingTimeInterval(delay.wallSeconds)
        enqueue(
            QueuedDelivery(
                entryID: key.entryID, destinationID: key.destinationID,
                attempt: attempt, nextAttemptAt: nextAt, resume: resume
            )
        )
        append(
            .queued, entryID: key.entryID, destination: destination,
            attempt: attempt, detail: error.localizedDescription
        )
        schedule(key, after: delay)
        return .queued(attempt: attempt, nextAt: nextAt)
    }

    /// Spaces out what fell due while Parola was quit, and keeps a timer a send armed before it ran.
    func resumeQueue() {
        let now = Date()
        var overdue = 0
        for item in queue {
            let key = QueueKey(entryID: item.entryID, destinationID: item.destinationID)
            guard timers[key] == nil, !inFlight.contains(key) else { continue }
            let remaining = item.nextAttemptAt.timeIntervalSince(now)
            if remaining > 0 {
                schedule(key, after: .seconds(remaining))
            } else {
                schedule(key, after: Self.catchUpSpacing * overdue)
                overdue += 1
            }
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

    /// A manual send or a cancel can settle the delivery during any await, so each is followed by a queue check.
    private func runQueued(_ key: QueueKey) async {
        timers[key] = nil
        guard isQueued(key) else { return }
        let stored = await destinationsProvider().first { $0.id == key.destinationID }
        guard isQueued(key) else { return }
        guard let destination = stored?.destination, destination.isEnabled else {
            dequeue(key)
            appendMissing(key, name: stored?.name ?? "", event: .skipped, detail: "the destination is gone or switched off")
            return
        }
        do {
            try await destination.checkReachable()
        } catch {
            guard isQueued(key) else { return }
            deferDueDeliveries(to: destination, after: key, error: error)
            return
        }
        guard isQueued(key) else { return }
        do {
            let payload = try await payloadProvider(key.entryID)
            guard isQueued(key) else { return }
            _ = await attempt(payload: payload, destination: destination)
        } catch let error as DeliveryPayloadError {
            let attempts = queueAttempt(key)
            dequeue(key)
            append(.dropped, entryID: key.entryID, destination: destination, attempt: attempts, detail: error.localizedDescription)
        } catch {
            _ = failed(key, destination: destination, attempt: queueAttempt(key) + 1, error: error)
        }
    }

    /// Out of reach is not an attempt: the delivery keeps its count and backs off on a clock of its own.
    private func waitForDestination(
        _ key: QueueKey, destination: any DeliveryDestination, error: any Error
    ) -> DeliveryOutcome {
        let current = queue.first { $0.entryID == key.entryID && $0.destinationID == key.destinationID }
        let attempts = current?.attempt ?? 0
        let checks = (current?.unreachableChecks ?? 0) + 1
        guard checks <= Self.maxUnreachableChecks else {
            dequeue(key)
            append(.dropped, entryID: key.entryID, destination: destination, attempt: attempts, detail: error.localizedDescription)
            return .skipped(reason: .givenUp(destination.name))
        }
        let delay = Self.delay(forAttempt: checks)
        let nextAt = Date().addingTimeInterval(delay.wallSeconds)
        enqueue(
            QueuedDelivery(
                entryID: key.entryID, destinationID: key.destinationID,
                attempt: attempts, nextAttemptAt: nextAt, unreachableChecks: checks, resume: current?.resume
            )
        )
        append(.queued, entryID: key.entryID, destination: destination, attempt: attempts, detail: error.localizedDescription)
        schedule(key, after: delay)
        return .queued(attempt: attempts, nextAt: nextAt)
    }

    /// One failed check stands for every delivery to that destination that was due by the time this one was.
    private func deferDueDeliveries(to destination: any DeliveryDestination, after key: QueueKey, error: any Error) {
        let firedAt = queue.first { $0.entryID == key.entryID && $0.destinationID == key.destinationID }?.nextAttemptAt
        let dueBy = max(Date(), firedAt ?? Date())
        let due = queue
            .filter { $0.destinationID == destination.id && $0.nextAttemptAt <= dueBy }
            .map { QueueKey(entryID: $0.entryID, destinationID: $0.destinationID) }
            .filter { !inFlight.contains($0) }
        for dueKey in due {
            _ = waitForDestination(dueKey, destination: destination, error: error)
        }
    }

    private func isQueued(_ key: QueueKey) -> Bool {
        queue.contains { $0.entryID == key.entryID && $0.destinationID == key.destinationID }
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
