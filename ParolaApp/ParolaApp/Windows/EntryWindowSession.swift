import AppKit
import AVFoundation
import Foundation
import Observation
import ParolaCore
import SwiftUI

/// One library entry open in a window of its own: its document, its own player and clock, its own search.
@MainActor
@Observable
final class EntryWindowSession {
    let entryID: LibraryEntry.ID

    private(set) var document: ParolaDocument?
    private(set) var title: String
    private(set) var isLoading = true
    private(set) var loadFailed = false

    private(set) var player: AVPlayer?
    private(set) var currentTime: Double = 0
    private(set) var isPlaying = false
    private(set) var currentSegmentID: TranscriptSegment.ID?
    var rate: Double { didSet { applyRate() } }

    var searchIsOpen = false
    var searchQuery: String = "" { didSet { scheduleMatchRecompute() } }
    private(set) var matches: [TranscriptMatch] = []
    private(set) var currentMatchIndex = 0
    var showsInfo = false

    @ObservationIgnored private let model: AppModel
    @ObservationIgnored private(set) var loadTask: Task<Void, Never>?
    @ObservationIgnored private var playerURL: URL?
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var statusObserver: NSKeyValueObservation?
    @ObservationIgnored private var matchesBySegment: [TranscriptSegment.ID: [TranscriptMatch]] = [:]
    @ObservationIgnored private var segmentsByID: [TranscriptSegment.ID: TranscriptSegment] = [:]
    @ObservationIgnored private var searchDebounceTask: Task<Void, Never>?
    @ObservationIgnored private(set) var appliedUpdatedAt: Date?
    /// Counts the bundle reads, so a test can tell a skipped reload from a silent one.
    @ObservationIgnored private(set) var loadGeneration = 0

    init(entryID: LibraryEntry.ID, model: AppModel) {
        self.entryID = entryID
        self.model = model
        let stored = model.defaults.object(forKey: "playbackRate") as? Double
        self.rate = (stored ?? 0) > 0 ? (stored ?? 1) : 1
        // The title the main window's header and the bridge's displayTitle use, so a driver finds it by name.
        self.title = model.libraryEntry(id: entryID)
            .map { LibraryEntryDisplay.title(for: $0) }
            ?? String(localized: "Transcript")
        load()
    }

    // MARK: - What the window shows

    var transcript: Transcript? { document?.transcript }

    /// The rows the window draws: every segment that has something to say, built once per load.
    private(set) var visibleSegments: [TranscriptSegment] = []

    func segment(_ id: TranscriptSegment.ID) -> TranscriptSegment? { segmentsByID[id] }

    var entry: LibraryEntry? { model.libraryEntry(id: entryID) }

    /// Rebuilt when the document lands, not per row: every visible row reads it.
    private(set) var favorites: Set<Int> = []

    var translations: [Int: String] { document?.transcript.translation?.segments ?? [:] }

    var translationLanguage: String? { document?.transcript.translation?.targetLanguage }

    var transcriptText: String { transcript?.text ?? "" }

    var speakers: [String] { transcript?.uniqueSpeakers ?? [] }

    var durationSeconds: Double {
        document?.transcript.durationSeconds ?? document?.manifest.durationSeconds ?? 0
    }

    /// The colour each speaker label wears in this window, read from this entry's own map.
    /// Cached with the document: rebuilding it cost a person lookup per assignment per row.
    private(set) var speakerColorIndices: [String: Int] = [:]

    private func rebuildSideMaps() {
        favorites = Set(document?.manifest.favoriteSegments ?? [])
        var indices: [String: Int] = [:]
        for (label, personID) in document?.manifest.speakerAssignments ?? [:] {
            guard let person = model.person(id: personID) else { continue }
            indices[label] = person.colorIndex
        }
        speakerColorIndices = indices
    }

    func isFavorite(_ segmentID: TranscriptSegment.ID) -> Bool {
        favorites.contains(segmentID)
    }

    // MARK: - Loading

    private func load() {
        startLoad(keepingPlace: false)
    }

    /// Re-reads the bundle after the library changed, keeping the window where the reader left it.
    func reload() {
        startLoad(keepingPlace: true)
    }

    /// What a library bump calls: any entry's change bumps the counter, only this one's is worth a read.
    func reloadIfEntryChanged() {
        guard let entry = model.libraryEntry(id: entryID) else {
            if !loadFailed { reload() }
            return
        }
        guard entry.updatedAt != appliedUpdatedAt else { return }
        reload()
    }

    private func startLoad(keepingPlace: Bool) {
        loadGeneration += 1
        loadTask?.cancel()
        loadTask = Task { [model, entryID] in
            do {
                let loaded = try await model.library.load(entryID)
                guard !Task.isCancelled else { return }
                apply(loaded, keepingPlace: keepingPlace)
            } catch {
                guard !Task.isCancelled else { return }
                markUnavailable()
            }
        }
    }

    private func apply(_ loaded: LoadedEntry, keepingPlace: Bool) {
        document = loaded.document
        title = LibraryEntryDisplay.title(for: loaded.entry)
        appliedUpdatedAt = loaded.entry.updatedAt
        isLoading = false
        loadFailed = false
        rebuildSegmentIndex()
        rebuildSideMaps()
        refreshMatches()
        let audioURL = loaded.document.audioURL
        if let audioURL, player == nil || !keepingPlace || audioURL != playerURL {
            installPlayer(for: audioURL)
        } else if audioURL == nil {
            tearDownPlayer()
        }
        // A reload can move the segment under a standing clock; a first load has no clock to honour.
        if keepingPlace { updateCurrentSegment(time: currentTime) }
    }

    private func markUnavailable() {
        document = nil
        appliedUpdatedAt = nil
        isLoading = false
        loadFailed = true
        rebuildSegmentIndex()
        rebuildSideMaps()
        refreshMatches()
        tearDownPlayer()
    }

    private func rebuildSegmentIndex() {
        let segments = transcript?.segments ?? []
        visibleSegments = segments.filter {
            !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        segmentsByID = Dictionary(segments.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// Frees the window's player and its observers. The registry calls this when the window closes.
    func release() {
        loadTask?.cancel()
        loadTask = nil
        searchDebounceTask?.cancel()
        searchDebounceTask = nil
        tearDownPlayer()
    }

    private func tearDownPlayer() {
        if let timeObserver, let player { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        statusObserver?.invalidate()
        statusObserver = nil
        player?.pause()
        player = nil
        playerURL = nil
        isPlaying = false
    }

    // MARK: - Playback

    private func installPlayer(for url: URL) {
        tearDownPlayer()
        playerURL = url
        let player = AVPlayer(url: url)
        player.defaultRate = Float(rate)
        self.player = player
        let interval = CMTime(seconds: 0.2, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            let seconds = CMTimeGetSeconds(time)
            Task { @MainActor in self?.clockAdvanced(to: seconds) }
        }
        statusObserver = player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
            let playing = player.timeControlStatus == .playing
            Task { @MainActor in
                guard let self, self.isPlaying != playing else { return }
                self.isPlaying = playing
            }
        }
    }

    private func clockAdvanced(to seconds: Double) {
        guard seconds.isFinite else { return }
        currentTime = seconds
        updateCurrentSegment(time: seconds)
    }

    func togglePlayPause() {
        guard let player else { return }
        if player.timeControlStatus == .playing {
            player.pause()
            return
        }
        if durationSeconds > 0, currentTime >= durationSeconds - 0.05 { scrub(to: 0) }
        player.play()
        player.rate = Float(rate)
    }

    /// Moves the window's clock even with no player behind it, so a media-less transcript still follows along.
    func scrub(to seconds: Double) {
        guard seconds.isFinite else { return }
        let target = durationSeconds > 0 ? min(max(0, seconds), durationSeconds) : max(0, seconds)
        currentTime = target
        updateCurrentSegment(time: target)
        player?.seek(to: CMTime(seconds: target, preferredTimescale: 600))
    }

    func seek(toSegment id: TranscriptSegment.ID) {
        guard let segment = transcript?.segments.first(where: { $0.id == id }) else { return }
        scrub(to: segment.start)
        player?.play()
    }

    func skip(by seconds: Double) {
        scrub(to: currentTime + seconds)
    }

    private func applyRate() {
        guard let player else { return }
        player.defaultRate = Float(rate)
        if player.timeControlStatus == .playing { player.rate = Float(rate) }
    }

    private func updateCurrentSegment(time: Double) {
        let id = transcript?.segments.binarySearchSegment(coveringTime: time)?.id
        if currentSegmentID != id { currentSegmentID = id }
    }

    // MARK: - Search

    func toggleSearch() {
        searchIsOpen.toggle()
        if !searchIsOpen { searchQuery = "" }
    }

    var currentMatch: TranscriptMatch? {
        matches.indices.contains(currentMatchIndex) ? matches[currentMatchIndex] : nil
    }

    func matches(in segmentID: TranscriptSegment.ID) -> [TranscriptMatch] {
        matchesBySegment[segmentID] ?? []
    }

    func goToNextMatch() {
        guard !matches.isEmpty else { return }
        currentMatchIndex = (currentMatchIndex + 1) % matches.count
        snapToCurrentMatch()
    }

    func goToPreviousMatch() {
        guard !matches.isEmpty else { return }
        currentMatchIndex = (currentMatchIndex - 1 + matches.count) % matches.count
        snapToCurrentMatch()
    }

    /// A keystroke must not scan the whole transcript: the scan follows the typing by ~150 ms.
    private func scheduleMatchRecompute() {
        searchDebounceTask?.cancel()
        guard !searchQuery.isEmpty else {
            recomputeMatches()
            return
        }
        searchDebounceTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            self?.recomputeMatches()
        }
    }

    private func recomputeMatches() {
        currentMatchIndex = 0
        refreshMatches()
        snapToCurrentMatch()
    }

    /// Re-runs the standing query over a transcript that changed under it, keeping the reader's place in the list.
    private func refreshMatches() {
        guard let transcript, !searchQuery.isEmpty else {
            matches = []
            matchesBySegment = [:]
            currentMatchIndex = 0
            return
        }
        matches = transcript.findMatches(searchQuery)
        matchesBySegment = Dictionary(grouping: matches, by: \.segmentID)
        currentMatchIndex = min(currentMatchIndex, max(matches.count - 1, 0))
    }

    private func snapToCurrentMatch() {
        guard let match = currentMatch else { return }
        currentSegmentID = match.segmentID
    }

    // MARK: - Copying

    func copyTranscript() {
        let text = transcriptText
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
