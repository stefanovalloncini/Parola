import AppKit
import Foundation
import ParolaCore

/// What a test note did, for the destination editor.
enum TestNoteOutcome: Equatable {
    case written(URL?)
    case failed(String)
}

/// What the transcript column says about the last delivery.
struct DeliveryNotice: Equatable {
    enum State: Equatable {
        case sent(URL?)
        case queued(Date)
        case failed(String)
    }

    let entryID: LibraryEntry.ID
    let destinationID: UUID
    let destinationName: String
    let state: State
}

/// Which Send To editor to open: a blank one for a kind, or the one for a destination in the list.
struct DestinationEditorRequest: Equatable {
    enum Target: Equatable {
        case new(DestinationKind)
        case existing(UUID)
    }

    let target: Target
    let token = UUID()
}

extension AppModel {

    var destinationsEnabled: Bool { features.isEnabled(.destinations) }

    var hasAutoSendDestination: Bool {
        destinationsEnabled && destinations.contains { $0.isEnabled && $0.autoSend }
    }

    /// The destinations the Send to menus offer.
    var sendableDestinations: [AnyDestination] {
        guard destinationsEnabled else { return [] }
        return destinations.filter { $0.isEnabled && $0.destination != nil }
    }

    /// The notice the transcript column shows: the one raised for the entry on screen, or any
    /// notice while nothing is open (a send from a library row).
    var visibleDeliveryNotice: DeliveryNotice? {
        guard let notice = deliveryNotice else { return nil }
        guard let selected = selectedEntryID else { return notice }
        return notice.entryID == selected ? notice : nil
    }

    var canSendOpenTranscript: Bool {
        destinationsEnabled && selectedEntryID != nil && !sendableDestinations.isEmpty
    }

    // MARK: - The list

    func loadDestinations() {
        setDestinations(readJSON([AnyDestination].self, forKey: "destinations") ?? [])
    }

    /// The one way the destination list changes: add, edit, remove and move all land here, and so
    /// does the bridge.
    func setDestinations(_ destinations: [AnyDestination]) {
        guard destinationsEnabled else { return }
        let bound = destinations.map { $0.bound(to: deliveryEnvironment) }
        let kept = Set(bound.flatMap(\.secretRefs))
        let orphaned = self.destinations.flatMap(\.secretRefs).filter { !kept.contains($0) }
        self.destinations = bound
        writeJSON(bound.filter(\.isPersistable), forKey: "destinations")
        if !orphaned.isEmpty {
            let secrets = deliveryEnvironment.secrets
            Task { await secrets.remove(orphaned) }
        }
    }

    func addDestination(_ destination: AnyDestination) {
        setDestinations(destinations + [destination])
    }

    /// An edit is often the fix for a folder that went missing, so what waited for it goes out now.
    func updateDestination(_ destination: AnyDestination) {
        guard let index = destinations.firstIndex(where: { $0.id == destination.id }) else {
            addDestination(destination)
            return
        }
        var updated = destinations
        updated[index] = destination
        setDestinations(updated)
        guard destinationsEnabled else { return }
        let engine = deliveryEngine
        Task { await engine.retryNow(destinationID: destination.id) }
    }

    func removeDestination(id: UUID) {
        setDestinations(destinations.filter { $0.id != id })
    }

    func moveDestination(id: UUID, by offset: Int) {
        guard let index = destinations.firstIndex(where: { $0.id == id }) else { return }
        let target = index + offset
        guard destinations.indices.contains(target) else { return }
        var updated = destinations
        updated.swapAt(index, target)
        setDestinations(updated)
    }

    func destination(id: UUID) -> AnyDestination? {
        destinations.first { $0.id == id }
    }

    // MARK: - The engine

    /// A `--library` override keeps its queue next to that library, so a test or the sandbox never
    /// writes into the real one under Application Support.
    var deliveryDirectory: URL {
        library.libraryURL == LibraryStore.defaultLibraryURL
            ? DeliveryQueueStore.defaultDirectory
            : library.libraryURL.appendingPathComponent("Delivery", isDirectory: true)
    }

    /// A vault on a drive that was just plugged in can take what queued for it without waiting out its backoff.
    func observeVolumeMounts(on center: NotificationCenter = NSWorkspace.shared.notificationCenter) {
        volumeMountObservation = NotificationObservation(
            center: center, name: NSWorkspace.didMountNotification
        ) { [weak self] in
            self?.retryDeliveriesAfterMount()
        }
    }

    func retryDeliveriesAfterMount() {
        guard destinationsEnabled else { return }
        let engine = deliveryEngine
        Task { await engine.retryNow() }
    }

    func makeDeliveryEngine() -> DeliveryEngine {
        let library = self.library
        return DeliveryEngine(
            destinations: { [weak self] in await self?.destinations ?? [] },
            payload: { entryID in
                try await DeliveryPayload.load(entryID, from: library)
            },
            store: DeliveryQueueStore(directory: deliveryDirectory),
            clock: clock,
            recordReceipt: { receipt, entryID in
                do {
                    try await library.appendDelivery(receipt, for: entryID)
                } catch {
                    ParolaLog.error(.library, "delivery receipt could not be saved", [.error: .error(error)])
                }
            }
        )
    }

    // MARK: - Sending

    /// The one entry point for a manual send: both menus, the toast's Retry and the bridge call this.
    @discardableResult
    func sendEntry(_ entryID: LibraryEntry.ID, to destinationID: UUID) async -> DeliveryOutcome? {
        guard destinationsEnabled else { return nil }
        let name = destination(id: destinationID)?.name ?? ""
        // The payload is read from the library, which is up to a second behind an edit.
        if entryID == selectedEntryID { await flushPendingTranscriptSave() }
        let outcome = await deliveryEngine.send(entryID: entryID, to: destinationID)
        deliveryNotice = DeliveryNotice(
            entryID: entryID,
            destinationID: destinationID,
            destinationName: name,
            state: Self.noticeState(for: outcome)
        )
        return outcome
    }

    /// Fans a finished transcription out to the auto-send destinations. The completion hook is the
    /// only caller; a batch run never reaches it.
    func autoSendEntry(_ entryID: LibraryEntry.ID) async {
        guard destinationsEnabled else { return }
        let collector = AttemptCollector()
        let attempts = await deliveryEngine.sendAutomatically(entryID: entryID) { [weak self] attempt in
            let landed = await collector.add(attempt)
            await self?.showAutoSendNotice(landed, entryID: entryID)
        }
        showAutoSendNotice(attempts, entryID: entryID)
    }

    private func showAutoSendNotice(_ attempts: [DeliveryAttempt], entryID: LibraryEntry.ID) {
        guard let notice = Self.notice(for: attempts, entryID: entryID) else { return }
        deliveryNotice = notice
    }

    /// One line for a fan-out: the first destination that did not deliver, or every destination
    /// that did.
    static func notice(for attempts: [DeliveryAttempt], entryID: LibraryEntry.ID) -> DeliveryNotice? {
        guard let first = attempts.first else { return nil }
        if let problem = attempts.first(where: { !$0.outcome.isDelivered }) {
            return DeliveryNotice(
                entryID: entryID,
                destinationID: problem.destinationID,
                destinationName: problem.destinationName,
                state: noticeState(for: problem.outcome)
            )
        }
        // Reveal can only point at one note, so it is offered when there is only one.
        let location = attempts.count == 1 ? first.outcome.receipt?.location : nil
        return DeliveryNotice(
            entryID: entryID,
            destinationID: first.destinationID,
            destinationName: attempts.map(\.destinationName).joined(separator: ", "),
            state: .sent(location)
        )
    }

    /// Retries what the toast is reporting. It goes through ``sendEntry(_:to:)`` so the attempt
    /// count keeps counting from the queue.
    func retryDelivery() async {
        guard let notice = deliveryNotice else { return }
        await sendEntry(notice.entryID, to: notice.destinationID)
    }

    func dismissDeliveryNotice() {
        deliveryNotice = nil
    }

    /// Writes one sample note so the editor can prove the folder and the template work. It never
    /// touches the library: nothing is recorded against an entry.
    func sendTestNote(to destination: ObsidianVaultFolderDestination) async -> TestNoteOutcome {
        guard destinationsEnabled else { return .failed(String(localized: "Send To is turned off.")) }
        do {
            let receipt = try await destination.deliver(Self.sampleDeliveryPayload())
            return .written(receipt.location)
        } catch {
            return .failed(FailureText.message(for: error))
        }
    }

    nonisolated static func sampleDeliveryPayload() -> DeliveryPayload {
        let segments = [
            TranscriptSegment(
                id: 0, start: 0, end: 4,
                text: String(localized: "This is a test note from Parola."),
                speaker: String(localized: "Speaker 1")
            ),
            TranscriptSegment(
                id: 1, start: 4, end: 9,
                text: String(localized: "If you can read it in your vault, the folder and the filename work."),
                speaker: String(localized: "Speaker 2")
            ),
        ]
        let transcript = Transcript(
            segments: segments,
            language: "en",
            modelName: "parola-sample",
            durationSeconds: 9
        )
        var spec = ExportSpec.standard(for: .md)
        spec.options.speakers = true
        let markdown = (try? Exporters.exporter(for: spec).renderText(transcript)) ?? ""
        return DeliveryPayload(
            entryID: "sample",
            title: String(localized: "Parola test note"),
            shortSummary: String(localized: "A sample Parola writes to check a destination."),
            createdAt: Date(),
            duration: 9,
            language: "en",
            modelName: "parola-sample",
            speakers: transcript.uniqueSpeakers,
            labels: [String(localized: "sample")],
            category: .transcription,
            transcript: transcript,
            favorites: [0],
            markdown: markdown
        )
    }

    // MARK: - Outcome to notice

    static func noticeState(for outcome: DeliveryOutcome) -> DeliveryNotice.State {
        switch outcome {
        case .delivered(let receipt): return .sent(receipt.location)
        case .queued(_, let nextAt): return .queued(nextAt)
        case .skipped(let reason): return .failed(FailureText.message(for: reason))
        }
    }
}

/// The outcomes of an automatic send as they land, one destination at a time.
private actor AttemptCollector {
    private var attempts: [DeliveryAttempt] = []

    func add(_ attempt: DeliveryAttempt) -> [DeliveryAttempt] {
        attempts.append(attempt)
        return attempts
    }
}

/// A notification observer that goes away with its owner.
final class NotificationObservation {
    private let center: NotificationCenter
    private let token: any NSObjectProtocol

    init(center: NotificationCenter, name: Notification.Name, handler: @escaping @MainActor () -> Void) {
        self.center = center
        token = center.addObserver(forName: name, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { handler() }
        }
    }

    deinit {
        center.removeObserver(token)
    }
}
