import Foundation
import ParolaCore
import Translation

enum TranslationState: Equatable, Sendable {
    case idle
    case preparing
    case translating(completed: Int, total: Int)
    case cancelling
    case failed(String)
}

/// Runs a transcript through a translator, batch by batch, and publishes how far it got.
///
/// The Translation framework only hands out a `TranslationSession` inside `.translationTask` on a
/// live view, so an Apple run is a handshake: the coordinator publishes a configuration,
/// ``TranslationHostView`` feeds it to the modifier and calls ``run(session:)`` back with the
/// session, and the caller's `await` resumes once that run finishes. A mock translator skips the
/// handshake and never touches the framework.
@MainActor
@Observable
final class TranslationCoordinator {
    struct Outcome: Sendable {
        var segments: [Int: String]
        var provider: String
        /// The run was cancelled, so `segments` holds only the batches that came back before.
        var cancelled = false
        /// A batch failed, so `segments` holds only the batches that came back before it.
        var failed = false
    }

    private struct PendingRun {
        let units: [TranslationBatcher.Unit]
        let source: String?
        let target: String
        let continuation: CheckedContinuation<Outcome?, Never>
    }

    private(set) var state: TranslationState = .idle
    /// Non-nil while a run waits for a live session; the host view feeds it to `.translationTask`.
    private(set) var sessionConfiguration: TranslationSession.Configuration?
    private(set) var activeEntryID: LibraryEntry.ID?
    /// The language the last run aimed at, so Retry can repeat it.
    private(set) var activeTarget: String?
    private(set) var activeProvider: String?
    /// The targets the last `supportedTargets()` found, for menus that can't wait on it.
    private(set) var knownTargets: [String]?

    /// Test seam: when set, replaces the resolved translator so a test never touches the shared mock registry.
    @ObservationIgnored var translatorOverride: (any TranscriptTranslating)?

    /// Test seam: when set, stands in for the languages the system translator offers.
    @ObservationIgnored var systemLanguagesOverride: [String]?

    /// How long a run waits for ``TranslationHostView`` to hand back a live session.
    @ObservationIgnored var sessionWaitBudget: Duration = .seconds(10)

    /// How long a cancelled run waits for the provider to give up its call before it lets go of it.
    @ObservationIgnored var cancelGrace: Duration = .seconds(10)

    @ObservationIgnored private var pending: PendingRun?
    @ObservationIgnored private(set) var cancelRequested = false
    @ObservationIgnored private var sessionWaitTask: Task<Void, Never>?
    @ObservationIgnored private var discardRequested = false
    @ObservationIgnored private var callWaiter: (id: Int, continuation: CheckedContinuation<Result<[Int: String], any Error>?, Never>)?
    @ObservationIgnored private var callSerial = 0
    @ObservationIgnored private var graceTask: Task<Void, Never>?
    @ObservationIgnored private(set) var completedSegments = 0
    @ObservationIgnored private var inFlightCall: Task<[Int: String], any Error>?
    @ObservationIgnored private var activeTranslator: (any TranscriptTranslating)?

    /// The state to show for an entry: a run belongs to the entry that started it, so switching
    /// entries mid-run leaves the other transcript's section idle.
    func state(for entryID: LibraryEntry.ID?) -> TranslationState {
        guard let entryID, entryID == activeEntryID else { return .idle }
        return state
    }

    var isRunning: Bool {
        switch state {
        case .preparing, .translating, .cancelling: return true
        case .idle, .failed: return false
        }
    }

    /// What a run in flight reports to the bridge, so a script can wait on a first translation
    /// instead of one that has already landed.
    struct RunSnapshot: Sendable {
        var targetLanguage: String
        var segmentCount: Int
        var provider: String
    }

    var runInProgress: RunSnapshot? {
        guard isRunning, let activeTarget, let activeProvider else { return nil }
        return RunSnapshot(targetLanguage: activeTarget, segmentCount: completedSegments, provider: activeProvider)
    }

    /// Whether this Mac can translate the pair. A transcript with no language of its own answers
    /// `.supported`: the framework detects the source itself and only then knows.
    func availability(source: String?, target: String) async -> LanguageAvailability.Status {
        guard let source, !source.isEmpty else { return .supported }
        return await Self.systemStatus(from: source, to: target)
    }

    /// The languages a translation can target, falling back to the app's own table when the system
    /// offers none.
    func supportedTargets() async -> [String] {
        let codes: [String]
        if let systemLanguagesOverride {
            codes = systemLanguagesOverride
        } else if stubTranslator() != nil {
            return SupportedLanguages.codes
        } else {
            codes = await Self.systemSupportedLanguages()
        }
        let targets = codes.isEmpty ? SupportedLanguages.codes : codes
        if knownTargets != targets { knownTargets = targets }
        return targets
    }

    // LanguageAvailability is not Sendable and its members run off the caller's actor, so it is
    // built and used entirely outside the main actor.
    private nonisolated static func systemSupportedLanguages() async -> [String] {
        let codes = await LanguageAvailability().supportedLanguages.compactMap { $0.languageCode?.identifier }
        return Array(Set(codes)).sorted()
    }

    private nonisolated static func systemStatus(from source: String, to target: String) async -> LanguageAvailability.Status {
        await LanguageAvailability().status(
            from: Locale.Language(identifier: source), to: Locale.Language(identifier: target)
        )
    }

    func translate(entryID: LibraryEntry.ID, transcript: Transcript, to target: String) async -> Outcome? {
        // One run at a time: a second `perform` loop would race the first for `state` and for the
        // outcome the caller writes to the entry.
        guard !isRunning else { return nil }
        cancelRequested = false
        discardRequested = false
        completedSegments = 0
        let units = TranslationBatcher.units(from: transcript.segments)
        guard !units.isEmpty else { return nil }
        activeEntryID = entryID
        activeTarget = target
        state = .preparing

        let source = Self.sourceLanguage(for: transcript.language)
        if let stub = stubTranslator() {
            activeProvider = stub.providerName
            return await perform(units: units, source: source, target: target, using: stub)
        }
        activeProvider = AppleTranslator.provider
        let status = await availability(source: source, target: target)
        guard !cancelRequested else {
            state = .idle
            return nil
        }
        guard status != .unsupported else {
            state = .failed(String(localized: "This Mac can't translate into that language."))
            return nil
        }
        return await withCheckedContinuation { continuation in
            pending = PendingRun(units: units, source: source, target: target, continuation: continuation)
            sessionConfiguration = TranslationSession.Configuration(
                source: source.map { Locale.Language(identifier: $0) },
                target: Locale.Language(identifier: target)
            )
            startSessionWait()
        }
    }

    /// The framework only hands a session to a live `.translationTask`. When no host view answers,
    /// the caller would wait in `.preparing` with nothing to cancel but the Cancel button.
    private func startSessionWait() {
        sessionWaitTask?.cancel()
        let budget = sessionWaitBudget
        sessionWaitTask = Task { [weak self] in
            try? await Task.sleep(for: budget)
            guard !Task.isCancelled else { return }
            self?.failSessionWait()
        }
    }

    private func failSessionWait() {
        guard let run = pending else { return }
        pending = nil
        sessionConfiguration = nil
        state = .failed(String(localized: "The system translator didn't start in time."))
        run.continuation.resume(returning: nil)
    }

    /// Called by ``TranslationHostView`` with the session the framework built for the published configuration.
    func run(session: TranslationSession) async {
        sessionWaitTask?.cancel()
        sessionWaitTask = nil
        guard let run = pending else { return }
        pending = nil
        let outcome = await perform(
            units: run.units, source: run.source, target: run.target, using: AppleTranslator(session: session)
        )
        run.continuation.resume(returning: outcome)
        sessionConfiguration = nil
    }

    /// Stops the call in flight and lands nothing from it; batches that already came back stay in the outcome.
    func cancel() {
        guard isRunning else { return }
        cancelRequested = true
        sessionWaitTask?.cancel()
        sessionWaitTask = nil
        if let run = pending {
            pending = nil
            sessionConfiguration = nil
            state = .idle
            run.continuation.resume(returning: nil)
            return
        }
        inFlightCall?.cancel()
        activeTranslator?.cancel()
        state = .cancelling
        graceTask?.cancel()
        graceTask = nil
        guard let id = callWaiter?.id else { return }
        let grace = cancelGrace
        graceTask = Task { [weak self] in
            try? await Task.sleep(for: grace)
            guard !Task.isCancelled else { return }
            self?.finishWait(id: id, with: nil)
        }
    }

    /// Resumes the wait on call `id` only; a late result or a stale timer from an earlier call finds another waiter and does nothing.
    private func finishWait(id: Int, with result: Result<[Int: String], any Error>?) {
        guard let waiter = callWaiter, waiter.id == id else { return }
        callWaiter = nil
        graceTask?.cancel()
        graceTask = nil
        waiter.continuation.resume(returning: result)
    }

    private func waitForCall(_ call: Task<[Int: String], any Error>) async -> Result<[Int: String], any Error>? {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                callSerial += 1
                let id = callSerial
                callWaiter = (id, continuation)
                Task { [weak self] in
                    let result = await call.result
                    self?.finishWait(id: id, with: result)
                }
            }
        } onCancel: { call.cancel() }
    }

    /// Clears the section for an entry whose translation is being removed. Another entry's run is
    /// left alone: its progress row, its Cancel and its claim on the coordinator all stay put.
    func remove(entryID: LibraryEntry.ID) {
        guard activeEntryID == entryID else { return }
        if isRunning { discardRequested = true }
        cancel()
        if let id = callWaiter?.id { finishWait(id: id, with: nil) }
        if state != .cancelling { state = .idle }
        activeEntryID = nil
        activeTarget = nil
        activeProvider = nil
    }

    private func perform(
        units: [TranslationBatcher.Unit], source: String?, target: String, using translator: any TranscriptTranslating
    ) async -> Outcome? {
        let total = units.count
        var translated: [Int: String] = [:]
        var sent = 0
        completedSegments = 0
        state = .translating(completed: 0, total: total)
        activeTranslator = translator
        defer {
            activeTranslator = nil
            graceTask?.cancel()
            graceTask = nil
        }
        for batch in TranslationBatcher.batches(units) {
            let call = Task { try await translator.translate(batch, from: source, to: target) }
            inFlightCall = call
            let result = await waitForCall(call)
            inFlightCall = nil
            if cancelRequested { break }
            do {
                translated.merge(try result?.get() ?? [:]) { _, new in new }
            } catch {
                // Earlier batches are already good text; a later failure keeps them.
                state = .failed(Self.message(for: error))
                return translated.isEmpty || discardRequested
                    ? nil
                    : Outcome(segments: translated, provider: translator.providerName, failed: true)
            }
            sent += batch.count
            completedSegments = sent
            state = .translating(completed: sent, total: total)
        }
        state = .idle
        if discardRequested { return nil }
        return translated.isEmpty ? nil : Outcome(segments: translated, provider: translator.providerName, cancelled: cancelRequested)
    }

    private func stubTranslator() -> (any TranscriptTranslating)? {
        if let translatorOverride { return translatorOverride }
        return MockTranslatorRegistry.shared.resolve()
    }

    /// A transcript that never settled on a language leaves the source open, and the framework detects it.
    static func sourceLanguage(for language: String) -> String? {
        SpokenLanguage.realCode(language)?.lowercased()
    }

    static func message(for error: any Error) -> String {
        if case TranslationError.unsupportedLanguagePairing = error {
            return String(localized: "This Mac can't translate into that language.")
        }
        return (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
