import AppKit
import Foundation
import SwiftUI
import Testing
import ParolaCore
@testable import Parola
import ParolaTestSupport

@MainActor
@Suite("Segment commands without the hover strip", .serialized)
struct SegmentCommandsTests {
    let model: AppModel

    init() {
        model = AppModel(skipBootstrap: true, defaults: temporaryDefaults(), libraryURL: makeTempLibraryURL("segmentcommands"))
        model.transcript = SegmentEditingTests.makeTranscript(["Hello world.", "Second segment.", "Third one."])
    }

    @Test("a click on a card with no audio still chooses it for the menus")
    func clickChoosesWithoutAudio() throws {
        let segment = try #require(model.transcript?.segments[1])
        #expect(model.player == nil)
        model.chooseSegment(segment)
        #expect(model.focusedSegmentIDForCommands == 1)
        #expect(model.hasCurrentSegment)
    }

    @Test("Edit Segment from Paragraphs brings the segments forward and asks that card for its field")
    func editFromParagraphs() throws {
        model.transcriptDisplayMode = .transcript
        model.chooseSegment(try #require(model.transcript?.segments[2]))

        model.editFocusedSegment()

        #expect(model.transcriptDisplayMode == .segments)
        #expect(model.transcriptPaneMode == .transcript)
        #expect(model.pendingSegmentEditID == 2)
        #expect(model.pendingRevealSegmentID == 2)
    }

    @Test("a pending edit is dropped once another segment is chosen")
    func pendingEditFollowsTheChoice() throws {
        model.chooseSegment(try #require(model.transcript?.segments[0]))
        model.editFocusedSegment()
        model.chooseSegment(try #require(model.transcript?.segments[1]))
        #expect(model.pendingSegmentEditID == nil)
    }

    @Test("Delete Segment removes the chosen segment and lets go of the choice")
    func deleteTheChosenSegment() throws {
        model.chooseSegment(try #require(model.transcript?.segments[1]))
        model.deleteFocusedSegment()
        let ids = model.transcript?.segments.map(\.id)
        #expect(ids == [0, 2])
        #expect(model.focusedSegmentIDForCommands == nil)
    }

    @Test("Add Note… opens the note sheet for the chosen segment of a saved transcript")
    func noteTheChosenSegment() throws {
        model.selectedEntryID = "entry"
        model.chooseSegment(try #require(model.transcript?.segments[2]))
        model.noteFocusedSegment()
        #expect(model.editingSegmentNote?.segment.id == 2)
    }

    @Test("with nothing chosen the commands do nothing")
    func nothingChosen() {
        model.editFocusedSegment()
        model.deleteFocusedSegment()
        #expect(model.pendingSegmentEditID == nil)
        #expect(model.transcript?.segments.count == 3)
    }

    private func hostCard(_ index: Int) throws -> HostedWindow {
        let segment = try #require(model.transcript?.segments[index])
        let card = SegmentCard(segment: segment, translation: nil, translationSideBySide: false)
            .environment(model)
            .frame(width: 600)
        return HostedWindow(card, width: 600, height: 200)
    }

    @Test("VoiceOver reaches every segment action on the card, with the strip hidden")
    func cardCarriesNamedActions() throws {
        model.selectedEntryID = "entry"
        let hosted = try hostCard(0)
        defer { hosted.close() }
        let actions = Set(HostedAccessibility.elements(in: hosted.host).flatMap(\.actions))
        for name in ["Edit Segment", "Favorite", "Add Note…", "Copy Segment", "Split Segment", "Merge with Next Segment", "Delete Segment"] {
            #expect(actions.contains(name), "missing \(name)")
        }
    }

    @Test("the card for a pending edit opens its field and clears the request")
    func cardTakesThePendingEdit() throws {
        model.pendingSegmentEditID = 1
        let hosted = try hostCard(1)
        defer { hosted.close() }
        hosted.host.layoutSubtreeIfNeeded()
        #expect(model.pendingSegmentEditID == nil)
    }

    @Test("a card leaves another segment's pending edit alone")
    func otherCardsIgnoreThePendingEdit() throws {
        model.pendingSegmentEditID = 2
        let hosted = try hostCard(1)
        defer { hosted.close() }
        #expect(model.pendingSegmentEditID == 2)
    }
}
