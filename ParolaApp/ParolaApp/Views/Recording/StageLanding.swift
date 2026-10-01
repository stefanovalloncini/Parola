import SwiftUI

/// What carries over from the Stage into the transcript a take lands as: the band drops into the media bar, the time into the bar's duration, the words into the transcript column.
enum StageLanding {
    enum Piece: Hashable, Sendable {
        case band, time, text
    }

    enum Side: Hashable, Sendable {
        case stage, transcript
    }

    struct ID: Hashable, Sendable {
        let piece: Piece
        let side: Side?
    }

    /// The two sides share a piece's id only while it carries over; otherwise each keeps one of its own, so nothing links.
    nonisolated static func id(_ piece: Piece, on side: Side, carries: Bool) -> ID {
        ID(piece: piece, side: carries ? nil : side)
    }

    /// Under Reduce Motion nothing carries over and the Stage and the transcript only crossfade.
    nonisolated static func carries(eligible: Bool, reduceMotion: Bool) -> Bool {
        eligible && !reduceMotion
    }

    /// The words move by their first line without resizing, so a long transcript isn't laid out again on every frame of the landing.
    nonisolated static func properties(_ piece: Piece) -> MatchedGeometryProperties {
        piece == .text ? .position : .frame
    }

    nonisolated static func anchor(_ piece: Piece) -> UnitPoint {
        piece == .text ? .topLeading : .center
    }

    /// The Stage offers its pieces only while its take winds down, so a new take's Stage never flies in out of a transcript.
    nonisolated static func stageOffers(_ state: RecordingSession.State) -> Bool {
        switch state {
        case .finishing, .transcribing, .done: true
        case .arming, .recording, .paused, .failed: false
        }
    }

    /// The transcript on screen is the window's take: over its working file until its save lands, then as its entry.
    @MainActor
    static func transcriptIsTheTake(_ model: AppModel) -> Bool {
        guard let take = model.recording else { return false }
        let file = model.sourceFileURL
        let overItsFile = file != nil && model.recordedTake?.file == file
        switch take.state {
        case .transcribing: return overItsFile
        case .done(let entryID): return overItsFile || (entryID != nil && model.selectedEntryID == entryID)
        default: return false
        }
    }
}

extension EnvironmentValues {
    /// Shared by the main window's Stage and transcript page, so a landing take's pieces can carry across the route change.
    @Entry var stageLanding: Namespace.ID?
}

extension View {
    /// A piece of the Stage, offered to the transcript while `take` winds down.
    func stageLanding(_ piece: StageLanding.Piece, from take: RecordingSession) -> some View {
        modifier(StageLandingMatch(piece: piece, side: .stage, offered: StageLanding.stageOffers(take.state)))
    }

    /// The transcript's place for a piece of the Stage, taken only when the transcript is the take that landed.
    func stageLandingDestination(_ piece: StageLanding.Piece) -> some View {
        modifier(StageLandingMatch(piece: piece, side: .transcript, offered: nil))
    }
}

/// Reads the session here rather than in the page it sits on, so a title typed during a take redraws this modifier alone.
private struct StageLandingMatch: ViewModifier {
    let piece: StageLanding.Piece
    let side: StageLanding.Side
    let offered: Bool?
    @Environment(AppModel.self) private var model: AppModel?
    @Environment(\.stageLanding) private var namespace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        if let namespace {
            let eligible = offered ?? (model.map { StageLanding.transcriptIsTheTake($0) } == true)
            content.matchedGeometryEffect(
                id: StageLanding.id(piece, on: side, carries: StageLanding.carries(eligible: eligible, reduceMotion: reduceMotion)),
                in: namespace,
                properties: StageLanding.properties(piece),
                anchor: StageLanding.anchor(piece)
            )
        } else {
            content
        }
    }
}
