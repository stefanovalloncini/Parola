import SwiftUI

/// What carries over from the Stage into the transcript a take lands as: the band drops into the media bar and the time into the bar's duration, while the Stage's words give way to the transcript's.
enum StageLanding {
    enum Piece: Hashable, Sendable {
        case band, time
    }

    enum Side: Hashable, Sendable {
        case stage, transcript
    }

    struct ID: Hashable, Sendable {
        let piece: Piece
        let side: Side?
    }

    /// The Stage's words, facts and controls are gone before the transcript's words begin, so the two never show at once.
    nonisolated static let stageLeaves: Double = 0.15
    nonisolated static let wordsWait: Double = 0.15
    nonisolated static let wordsArrive: Double = 0.25

    static var stageLeaving: Animation { .easeOut(duration: stageLeaves) }
    static var wordsArriving: Animation { .easeOut(duration: wordsArrive).delay(wordsWait) }

    /// The two sides share a piece's id only while it carries over; otherwise each keeps one of its own, so nothing links.
    nonisolated static func id(_ piece: Piece, on side: Side, carries: Bool) -> ID {
        ID(piece: piece, side: carries ? nil : side)
    }

    /// Under Reduce Motion nothing carries over and the Stage and the transcript only crossfade.
    nonisolated static func carries(eligible: Bool, reduceMotion: Bool) -> Bool {
        eligible && !reduceMotion
    }

    /// The Stage offers its pieces only while its take winds down, so a new take's Stage never flies in out of a transcript.
    nonisolated static func stageOffers(_ state: RecordingSession.State) -> Bool {
        switch state {
        case .finishing, .transcribing, .done: true
        case .arming, .recording, .paused, .failed: false
        }
    }

    /// A Stage is on its way out for good once the route moves off it, so a page picked mid-landing never brings its words back.
    @MainActor
    static func stageIsLeaving(_ model: AppModel) -> Bool {
        model.route != .recording
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
    /// The page appears in the very change that takes the window off the Stage.
    @Entry var arrivesFromStage = false
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

    /// A part of the Stage that carries nothing over, gone fast as the Stage leaves.
    func leavesFirst() -> some View {
        modifier(LeavesFirst())
    }

    /// The transcript's words, held back as a landing's Stage leaves and brought in after it; `landing` counts only as the page is made.
    func arrivesAfterTheStage(_ landing: Bool) -> some View {
        modifier(ArrivesAfterTheStage(waits: landing))
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
                in: namespace
            )
        } else {
            content
        }
    }
}

/// Reads the model, not the environment: a Stage already on its way out still follows the model, but not new environment values.
private struct LeavesFirst: ViewModifier {
    @Environment(AppModel.self) private var model: AppModel?

    func body(content: Content) -> some View {
        let leaves = model.map { StageLanding.stageIsLeaving($0) } == true
        content
            .opacity(leaves ? 0 : 1)
            .animation(StageLanding.stageLeaving, value: leaves)
    }
}

/// Latched as state when the page is made: the route that brought it has already moved on by the time it appears.
private struct ArrivesAfterTheStage: ViewModifier {
    @State private var waits: Bool

    init(waits: Bool) {
        _waits = State(initialValue: waits)
    }

    func body(content: Content) -> some View {
        content
            .opacity(waits ? 0 : 1)
            .onAppear {
                guard waits else { return }
                withAnimation(StageLanding.wordsArriving) { waits = false }
            }
    }
}
