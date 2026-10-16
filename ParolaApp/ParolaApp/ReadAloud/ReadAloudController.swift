import AVFAudio
import AppKit
import Foundation
import MediaPlayer
import Observation
import ParolaCore
import ParolaSpeech

@MainActor
@Observable
final class ReadAloudController {
    enum PauseReason: String, Sendable, Hashable, CaseIterable {
        case user, take, dictation, captions, media, sleep, sessionInactive, outputChanged
    }

    enum WaitReason: Sendable, Hashable {
        case slow
    }

    enum State: Equatable, Sendable {
        case idle
        case preparing
        case reading
        case paused(PauseReason)
        case waiting(WaitReason)
        case failed(String)
        case noVoice(String)
    }

    enum BlockedReason: String, Sendable, Hashable {
        case take, dictation, captions

        var pauseReason: PauseReason {
            switch self {
            case .take: .take
            case .dictation: .dictation
            case .captions: .captions
            }
        }

        var message: String {
            switch self {
            case .take: String(localized: "Reading waits until the recording ends.")
            case .dictation: String(localized: "Reading waits until dictation ends.")
            case .captions: String(localized: "Reading waits until live captions stop.")
            }
        }
    }

    struct Item: Equatable, Sendable {
        var entryID: String
        var source: ReadingSource
        var title: String
        var language: String
        var voice: VoiceID
        var unitIndex: Int
        var unitCount: Int
    }

    struct Plan: Sendable {
        var entryID: String
        var source: ReadingSource
        var title: String
        var language: String
        var units: [ReadingUnit]
        var voice: VoiceID = .appleAutomatic
    }

    struct VoicePrompt: Identifiable, Equatable {
        enum Origin: Equatable {
            case main
            case entryWindow(String)
        }

        enum Mode: String, Equatable {
            case choose
            case noVoice
        }

        let id = UUID()
        var language: String
        var mode: Mode
        var request: ReadAloudRequest?
        var origin: Origin
    }

    static let refusalWindow: Duration = .seconds(2)
    static let speeds: [Double] = [0.75, 1, 1.25, 1.5, 2]

    private(set) var state: State = .idle {
        didSet { if oldValue != state { stateChanged() } }
    }
    private(set) var item: Item?
    private(set) var readingAnchors: [ReadingUnit.Anchored] = []
    private(set) var speed: Double = 1
    var voicePrompt: VoicePrompt?
    private(set) var previewing: VoiceID?

    @ObservationIgnored private let environment: ReadAloudEnvironment
    @ObservationIgnored private var system: (sink: any ReadAloudOutputSink, nowPlaying: any NowPlayingPublishing)?
    @ObservationIgnored private var session: ReadAloudSession?
    @ObservationIgnored private var eventsTask: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var focusGeneration = 0
    @ObservationIgnored private var hasPlayed = false
    @ObservationIgnored private var plan: Plan?
    @ObservationIgnored private var previewSession: ReadAloudSession?
    @ObservationIgnored private var previewTask: Task<Void, Never>?
    @ObservationIgnored private var observers: [(center: NotificationCenter, token: any NSObjectProtocol)] = []
    @ObservationIgnored private var refusalTask: Task<Void, Never>?
    @ObservationIgnored private var wasBlocked = false
    @ObservationIgnored private var blockDelivery: Task<Void, Never>?
    @ObservationIgnored private(set) var isInRefusalWindow = false
    @ObservationIgnored private var blockedProvider: @MainActor () -> BlockedReason? = { nil }
    @ObservationIgnored private var introductionProvider: @MainActor () -> Bool = { false }
    @ObservationIgnored private var playersProvider: @MainActor () -> [PlayerHandle] = { [] }

    init(environment: ReadAloudEnvironment) {
        self.environment = environment
        observeVoiceChanges()
    }

    // MARK: - Wiring

    func bind(
        blocked: @escaping @MainActor () -> BlockedReason?,
        introductionShown: @escaping @MainActor () -> Bool,
        players: @escaping @MainActor () -> [PlayerHandle]
    ) {
        blockedProvider = blocked
        introductionProvider = introductionShown
        playersProvider = players
        wasBlocked = blocked() != nil
        trackFocus()
    }

    func refocus() {
        focusChanged()
        trackFocus()
    }

    private func trackFocus() {
        focusGeneration += 1
        let mine = focusGeneration
        withObservationTracking {
            _ = blockedProvider()
            _ = introductionProvider()
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, mine == self.focusGeneration else { return }
                self.focusChanged()
                self.trackFocus()
            }
        }
    }

    /// The returned task ends once the session knows about the block or its end.
    @discardableResult
    func focusChanged() -> Task<Void, Never>? {
        if introductionProvider() {
            Task { await stop() }
            return nil
        }
        if let blocked = blockedProvider() {
            wasBlocked = true
            refusalTask?.cancel()
            isInRefusalWindow = false
            yieldNow(to: blocked.pauseReason)
            return deliverBlock(true)
        } else if wasBlocked {
            wasBlocked = false
            openRefusalWindow()
            return deliverBlock(false)
        }
        return nil
    }

    private func deliverBlock(_ blocked: Bool) -> Task<Void, Never> {
        let session = session
        let previous = blockDelivery
        let delivery = Task {
            await previous?.value
            await session?.setBlocked(blocked)
        }
        blockDelivery = delivery
        return delivery
    }

    private func openRefusalWindow() {
        isInRefusalWindow = true
        refusalTask?.cancel()
        refusalTask = Task { [weak self, clock = environment.clock] in
            try? await clock.sleep(for: Self.refusalWindow)
            guard !Task.isCancelled else { return }
            self?.isInRefusalWindow = false
        }
    }

    // MARK: - What the surfaces read

    var readingBlockedReason: BlockedReason? { blockedProvider() }

    var readingOwnsKeys: Bool {
        switch state {
        case .preparing, .reading, .waiting: true
        case .paused(let reason): reason != .media
        case .idle, .failed, .noVoice: false
        }
    }

    func reads(entryID: String, source: ReadingSource) -> Bool {
        guard let item, item.entryID == entryID else { return false }
        switch (item.source, source) {
        case (.transcript, .transcript), (.summary, .summary): return true
        case (.translation(let lhs), .translation(let rhs)): return lhs == rhs
        default: return false
        }
    }

    func reads(entryID: String, inPane kind: ReadAloudRequest.Kind) -> Bool {
        guard let item, item.entryID == entryID else { return false }
        switch (item.source, kind) {
        case (.transcript, .transcript), (.translation, .transcript), (.summary, .summary): return true
        default: return false
        }
    }

    // MARK: - Reading

    func start(_ plan: Plan, startAt: Int = 0) async {
        guard blockedProvider() == nil else { return }
        await stopPreview()
        generation += 1
        let mine = generation
        self.plan = plan
        tearDownSession()
        readingAnchors = []
        let voice = plan.voice
        item = Item(
            entryID: plan.entryID, source: plan.source, title: plan.title, language: plan.language, voice: voice,
            unitIndex: min(startAt, max(plan.units.count - 1, 0)), unitCount: plan.units.count
        )
        state = .preparing
        pausePlayers()
        let previous = session
        session = nil
        await previous?.stop()
        guard mine == generation else { return }

        let base = SpokenLanguage.baseCode(plan.language)
        let renderer = environment.renderer()
        let languages = renderer.capabilities.languages
        guard languages.isEmpty || languages.contains(base) else {
            state = .noVoice(plan.language)
            return
        }
        let sink: any ReadAloudOutputSink
        do {
            sink = try ensureSystem().sink
            refreshNowPlaying()
        } catch {
            ParolaLog.error(.readAloud, "the read-aloud output could not be created", [.error: .error(error)])
            state = .failed(String(localized: "Couldn't open the audio output."))
            return
        }
        let created = ReadAloudSession(
            units: plan.units, renderer: renderer, voice: voice, language: plan.language, sink: sink,
            clock: environment.clock, startAt: startAt
        )
        session = created
        hasPlayed = false
        consume(created.events, generation: mine)
        await created.setSpeed(speed)
        await created.setBlocked(blockedProvider() != nil)
        do {
            try await created.prewarm()
        } catch is CancellationError {
            return
        } catch let failure as AppleSpeechRenderer.Failure {
            guard mine == generation else { return }
            if case .noVoice = failure {
                state = .noVoice(plan.language)
            } else {
                state = .failed(failureMessage(for: voice, language: plan.language))
            }
            await tearDown(created)
            return
        } catch {
            guard mine == generation else { return }
            ParolaLog.error(.readAloud, "the voice could not be prepared", [.error: .error(error)])
            state = .failed(failureMessage(for: voice, language: plan.language))
            await tearDown(created)
            return
        }
        guard mine == generation else { return }
        if case .paused = state { return }
        hasPlayed = true
        ParolaLog.info(.readAloud, "reading started", [.count: .int(plan.units.count)])
        await created.play()
    }

    func retry() async {
        guard case .failed = state, let plan, let item else { return }
        await start(plan, startAt: item.unitIndex)
    }

    func pause() async {
        switch state {
        case .preparing, .reading, .waiting:
            await yield(to: .user, fade: true)
        default:
            return
        }
    }

    @discardableResult
    func resume() async -> Bool {
        guard blockedProvider() == nil else { return false }
        await stopPreview()
        switch state {
        case .waiting:
            state = .reading
            await session?.continueReading()
            return true
        case .paused:
            guard let session else { return false }
            pausePlayers()
            await session.setBlocked(false)
            guard case .paused = state, blockedProvider() == nil else { return false }
            if hasPlayed {
                state = .reading
                await session.resume()
            } else {
                state = .preparing
                hasPlayed = true
                await session.play()
            }
            return true
        default:
            return false
        }
    }

    func skip(by direction: Int) async {
        guard blockedProvider() == nil, hasPlayed, let session, direction != 0 else { return }
        switch state {
        case .reading, .waiting, .paused:
            if direction > 0 { await session.next() } else { await session.previous() }
        default:
            return
        }
    }

    func stop() async {
        await stopPreview()
        generation += 1
        let ending = session
        tearDownSession()
        state = .idle
        item = nil
        plan = nil
        readingAnchors = []
        await ending?.stop()
    }

    func setSpeed(_ value: Double) {
        let allowed = Self.speeds.contains(value) ? value : 1
        speed = allowed
        guard let session else { return }
        Task { await session.setSpeed(allowed) }
    }

    /// Withdraws Now Playing and marks the reading paused before the first suspension; the task ends once the output has paused.
    @discardableResult
    func yieldNow(to reason: PauseReason, fade: Bool = false) -> Task<Void, Never>? {
        guard beginYield(to: reason) else { return nil }
        guard hasPlayed, let session else { return nil }
        return Task { await session.pause(fade: fade) }
    }

    func yield(to reason: PauseReason, fade: Bool = false) async {
        await yieldNow(to: reason, fade: fade)?.value
    }

    private func beginYield(to reason: PauseReason) -> Bool {
        switch state {
        case .idle, .failed, .noVoice:
            return false
        case .paused:
            state = .paused(reason)
            return false
        case .preparing, .reading, .waiting:
            state = .paused(reason)
            return true
        }
    }

    func mediaStartedPlaying() {
        switch state {
        case .paused:
            state = .paused(.media)
        case .preparing, .reading, .waiting:
            yieldNow(to: .media)
        case .idle, .failed, .noVoice:
            return
        }
    }

    func entryRemoved(_ entryID: String) {
        guard item?.entryID == entryID else { return }
        Task { await stop() }
    }

    func terminate() {
        previewTask?.cancel()
        previewTask = nil
        previewSession = nil
        previewing = nil
        generation += 1
        eventsTask?.cancel()
        eventsTask = nil
        system?.nowPlaying.withdraw()
        system?.sink.stop()
        session = nil
        state = .idle
        item = nil
        plan = nil
        readingAnchors = []
    }

    func refreshVoices() {
        environment.refreshVoices()
    }

    // MARK: - Voices

    var appleInventory: AppleVoiceInventory { environment.appleVoices() }
    var personalVoiceStatus: PersonalVoiceStatus { environment.personalVoiceStatus() }

    func requestPersonalVoice() async -> PersonalVoiceStatus {
        await environment.requestPersonalVoice()
    }

    func openURL(_ url: URL) -> Bool {
        environment.openURL(url)
    }

    func present(_ prompt: VoicePrompt) {
        voicePrompt = prompt
    }

    func dismissVoicePrompt() {
        voicePrompt = nil
    }

    func declareNoVoice(_ plan: Plan, prompt: VoicePrompt) async {
        await stop()
        item = Item(
            entryID: plan.entryID, source: plan.source, title: plan.title, language: plan.language,
            voice: plan.voice, unitIndex: 0, unitCount: plan.units.count
        )
        state = .noVoice(plan.language)
        voicePrompt = prompt
    }

    func failureMessage(for voice: VoiceID, language: String) -> String {
        let name = ReadAloudVoices.spokenName(of: voice, language: language, in: environment.appleVoices())
        return String(localized: "Couldn't continue with \(name).")
    }

    /// Pauses a running reading, then plays one fixed sentence in `voice` on the shared output.
    @discardableResult
    func preview(_ voice: VoiceID, language: String) async -> Bool {
        guard blockedProvider() == nil else { return false }
        await stopPreview()
        switch state {
        case .preparing, .reading, .waiting: await yield(to: .user, fade: true)
        default: break
        }
        guard blockedProvider() == nil else { return false }
        let sink: any ReadAloudOutputSink
        do {
            sink = try ensureSystem().sink
        } catch {
            ParolaLog.error(.readAloud, "the preview output could not be created", [.error: .error(error)])
            return false
        }
        let unit = ReadingUnit(
            id: 0, text: ReadAloudVoices.sampleSentence(for: language), anchors: [], language: language, pauseAfter: 0
        )
        let made = ReadAloudSession(
            units: [unit], renderer: (environment.previewRenderer ?? environment.renderer)(), voice: voice,
            language: language, sink: sink, clock: environment.clock
        )
        previewSession = made
        previewing = voice
        let events = made.events
        previewTask = Task { [weak self] in
            for await event in events {
                switch event {
                case .finished, .failed, .interrupted:
                    guard let self, self.previewSession === made else { return }
                    self.previewSession = nil
                    self.previewing = nil
                    return
                default:
                    continue
                }
            }
        }
        await made.setSpeed(speed)
        await made.play()
        return true
    }

    func stopPreview() async {
        previewTask?.cancel()
        previewTask = nil
        previewing = nil
        guard let ending = previewSession else { return }
        previewSession = nil
        await ending.stop()
    }

    var mockVoice: MockVoiceSettings? { environment.mockVoice }
    var nowPlayingPublisher: (any NowPlayingPublishing)? { system?.nowPlaying }
    var outputSink: (any ReadAloudOutputSink)? { system?.sink }

    // MARK: - Session

    private func ensureSystem() throws -> (sink: any ReadAloudOutputSink, nowPlaying: any NowPlayingPublishing) {
        if let system { return system }
        let sink = try environment.sink()
        let nowPlaying = environment.nowPlaying()
        nowPlaying.onCommand = { [weak self] command in
            self?.handle(command) ?? .noActionableNowPlayingItem
        }
        let made = (sink: sink, nowPlaying: nowPlaying)
        system = made
        observeSystemEvents()
        return made
    }

    private func consume(_ events: AsyncStream<ReadAloudSessionEvent>, generation mine: Int) {
        eventsTask?.cancel()
        eventsTask = Task { [weak self] in
            for await event in events {
                guard !Task.isCancelled else { return }
                self?.handle(event, generation: mine)
            }
        }
    }

    private func handle(_ event: ReadAloudSessionEvent, generation mine: Int) {
        guard mine == generation else { return }
        switch event {
        case .unitStarted(let index, let anchors):
            item?.unitIndex = index
            readingAnchors = anchors
            switch state {
            case .preparing, .waiting: state = .reading
            default: refreshNowPlaying()
            }
        case .waiting:
            if isRunning { state = .waiting(.slow) }
        case .interrupted:
            if isRunning { state = .paused(.outputChanged) }
        case .finished:
            ParolaLog.info(.readAloud, "reading finished")
            finishReading()
        case .failed(_, let unit):
            ParolaLog.error(.readAloud, "the reading failed")
            item?.unitIndex = unit
            readingAnchors = []
            session = nil
            hasPlayed = false
            state = .failed(failureMessage(for: item?.voice ?? .appleAutomatic, language: item?.language ?? ""))
        }
    }

    private var isRunning: Bool {
        switch state {
        case .preparing, .reading, .waiting: true
        default: false
        }
    }

    private func finishReading() {
        generation += 1
        eventsTask?.cancel()
        eventsTask = nil
        session = nil
        hasPlayed = false
        plan = nil
        item = nil
        readingAnchors = []
        state = .idle
    }

    private func tearDownSession() {
        eventsTask?.cancel()
        eventsTask = nil
        hasPlayed = false
    }

    private func tearDown(_ ended: ReadAloudSession) async {
        if session === ended { session = nil }
        hasPlayed = false
        await ended.stop()
    }

    private func pausePlayers() {
        for player in playersProvider() where player.isPlaying() {
            player.pause()
        }
    }

    // MARK: - Now Playing

    private func stateChanged() {
        refreshNowPlaying()
    }

    private func refreshNowPlaying() {
        guard let nowPlaying = system?.nowPlaying else { return }
        guard let item, publishes else {
            nowPlaying.withdraw()
            return
        }
        let playing: Bool
        switch state {
        case .preparing, .reading: playing = true
        default: playing = false
        }
        nowPlaying.publish(
            title: "\(Self.label(of: item.source)) · \(item.title)",
            unitIndex: item.unitIndex,
            unitCount: item.unitCount,
            isPlaying: playing
        )
    }

    private var publishes: Bool {
        switch state {
        case .preparing, .reading, .waiting: true
        case .paused(let reason): [.user, .sleep, .sessionInactive, .outputChanged].contains(reason)
        case .idle, .failed, .noVoice: false
        }
    }

    static func label(of source: ReadingSource) -> String {
        switch source {
        case .transcript: String(localized: "Transcript")
        case .summary: String(localized: "Summary")
        case .translation: String(localized: "Translation")
        }
    }

    var nowPlayingRefused: Bool { blockedProvider() != nil || isInRefusalWindow }

    func handle(_ command: NowPlayingCommand) -> MPRemoteCommandHandlerStatus {
        guard item != nil else { return .noActionableNowPlayingItem }
        switch command {
        case .pause:
            Task { await pause() }
            return .success
        case .play:
            return isRunning ? .success : startRemote { await self.resume() }
        case .toggle:
            if isRunning, case .reading = state {
                Task { await pause() }
                return .success
            }
            return startRemote { await self.resume() }
        case .next:
            return startRemote { await self.skip(by: 1) }
        case .previous:
            return startRemote { await self.skip(by: -1) }
        }
    }

    private func startRemote(_ action: @escaping @MainActor () async -> some Any) -> MPRemoteCommandHandlerStatus {
        guard !nowPlayingRefused else { return .commandFailed }
        Task { _ = await action() }
        return .success
    }

    // MARK: - System events

    private func observeSystemEvents() {
        let center = environment.systemNotifications()
        add(NSWorkspace.willSleepNotification, on: center) { [weak self] in self?.yieldNow(to: .sleep) }
        add(NSWorkspace.sessionDidResignActiveNotification, on: center) { [weak self] in
            self?.yieldNow(to: .sessionInactive)
        }
    }

    private func observeVoiceChanges() {
        let center = environment.appNotifications
        add(AVSpeechSynthesizer.availableVoicesDidChangeNotification, on: center) { [weak self] in
            self?.refreshVoices()
        }
        add(NSApplication.didBecomeActiveNotification, on: center) { [weak self] in self?.refreshVoices() }
    }

    private func add(_ name: Notification.Name, on center: NotificationCenter, _ action: @escaping @MainActor () -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { action() }
        }
        observers.append((center, token))
    }
}

extension ReadAloudController.State {
    var name: String {
        switch self {
        case .idle: "idle"
        case .preparing: "preparing"
        case .reading: "reading"
        case .paused: "paused"
        case .waiting: "waiting"
        case .failed: "failed"
        case .noVoice: "noVoice"
        }
    }

    var pauseReason: ReadAloudController.PauseReason? {
        if case .paused(let reason) = self { return reason }
        return nil
    }
}
