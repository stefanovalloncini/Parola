import AppKit
import AVFoundation
import Foundation
import Observation
import ParolaCore
import SwiftUI

/// One library entry open in a window of its own: the document it shows, its own player and clock,
/// and the search inside that window. Nothing here reaches the main window's transcript or player.
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
    var searchQuery: String = "" { didSet { recomputeMatches() } }
    private(set) var matches: [TranscriptMatch] = []
    private(set) var currentMatchIndex = 0
    var showsInfo = false

    @ObservationIgnored private let model: AppModel
    @ObservationIgnored private(set) var loadTask: Task<Void, Never>?
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var statusObserver: NSKeyValueObservation?
    @ObservationIgnored private var matchesBySegment: [TranscriptSegment.ID: [TranscriptMatch]] = [:]

    init(entryID: LibraryEntry.ID, model: AppModel) {
        self.entryID = entryID
        self.model = model
        let stored = model.defaults.object(forKey: "playbackRate") as? Double
        self.rate = (stored ?? 0) > 0 ? (stored ?? 1) : 1
        // The title the main window's header and the bridge's displayTitle use, so a driver
        // looking for this window by name finds it.
        self.title = model.libraryEntry(id: entryID)
            .map { LibraryEntryDisplay.title(for: $0) }
            ?? String(localized: "Transcript")
        load()
    }

    // MARK: - What the window shows

    var transcript: Transcript? { document?.transcript }

    var entry: LibraryEntry? { model.libraryEntry(id: entryID) }

    var favorites: Set<Int> { Set(document?.manifest.favoriteSegments ?? []) }

    var translations: [Int: String] { document?.transcript.translation?.segments ?? [:] }

    var translationLanguage: String? { document?.transcript.translation?.targetLanguage }

    var transcriptText: String { transcript?.text ?? "" }

    var speakers: [String] { transcript?.uniqueSpeakers ?? [] }

    var durationSeconds: Double {
        document?.transcript.durationSeconds ?? document?.manifest.durationSeconds ?? 0
    }

    /// The colour each speaker label wears in this window, read from this entry's own map.
    var speakerColorIndices: [String: Int] {
        var indices: [String: Int] = [:]
        for (label, personID) in document?.manifest.speakerAssignments ?? [:] {
            guard let person = model.person(id: personID) else { continue }
            indices[label] = person.colorIndex
        }
        return indices
    }

    func isFavorite(_ segmentID: TranscriptSegment.ID) -> Bool {
        favorites.contains(segmentID)
    }

    // MARK: - Loading

    private func load() {
        loadTask = Task { [model, entryID] in
            do {
                let loaded = try await model.library.load(entryID)
                guard !Task.isCancelled else { return }
                apply(loaded)
            } catch {
                guard !Task.isCancelled else { return }
                isLoading = false
                loadFailed = true
            }
        }
    }

    private func apply(_ loaded: LoadedEntry) {
        document = loaded.document
        title = LibraryEntryDisplay.title(for: loaded.entry)
        isLoading = false
        loadFailed = false
        if let audioURL = loaded.document.audioURL { installPlayer(for: audioURL) }
    }

    /// Frees the window's player and its observers. The registry calls this when the window closes.
    func release() {
        loadTask?.cancel()
        loadTask = nil
        if let timeObserver, let player { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        statusObserver?.invalidate()
        statusObserver = nil
        player?.pause()
        player = nil
        isPlaying = false
    }

    // MARK: - Playback

    private func installPlayer(for url: URL) {
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

    /// Moves the window's clock, with or without a player behind it: a transcript imported without
    /// its media still follows the segment the scrubber names.
    func scrub(to seconds: Double) {
        guard seconds.isFinite else { return }
        let target = max(0, seconds)
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

    private func recomputeMatches() {
        currentMatchIndex = 0
        guard let transcript, !searchQuery.isEmpty else {
            matches = []
            matchesBySegment = [:]
            return
        }
        matches = transcript.findMatches(searchQuery)
        matchesBySegment = Dictionary(grouping: matches, by: \.segmentID)
        snapToCurrentMatch()
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
