import Foundation
import SwiftUI
import Testing
@testable import Parola
import ParolaCore

@MainActor
@Suite("Stage sidebar")
struct StageSidebarTests {
    private func take(_ state: (inout RecordingSession) -> Void = { _ in }) -> RecordingSession {
        var session = RecordingSession(
            takeID: 1, source: .microphone, category: .transcription, title: "R", isStreaming: false, arming: .startingCapture
        )
        state(&session)
        return session
    }

    @Test("a take folds the sidebar away and gives it back")
    func foldsAndReturns() {
        let sidebar = MainSidebar()
        sidebar.hold(true, animation: nil)
        #expect(sidebar.visibility == .detailOnly)
        sidebar.hold(false, animation: nil)
        #expect(sidebar.visibility == .automatic)
    }

    @Test("a sidebar hidden before the take stays hidden after it")
    func hiddenStaysHidden() {
        let sidebar = MainSidebar()
        sidebar.userSet(.detailOnly)
        sidebar.hold(true, animation: nil)
        sidebar.hold(false, animation: nil)
        #expect(sidebar.visibility == .detailOnly)
    }

    @Test("a sidebar the user reopens during the take stays open when it ends")
    func reopenedStaysOpen() {
        let sidebar = MainSidebar()
        sidebar.hold(true, animation: nil)
        sidebar.userSet(.all)
        #expect(sidebar.visibility == .all)
        sidebar.hold(false, animation: nil)
        #expect(sidebar.visibility == .all)
    }

    @Test("the split view repeating the fold back is not the user moving the sidebar")
    func echoIsNotAMove() {
        let sidebar = MainSidebar()
        sidebar.hold(true, animation: nil)
        sidebar.userSet(.detailOnly)
        sidebar.hold(false, animation: nil)
        #expect(sidebar.visibility == .automatic)
    }

    @Test("a take that follows another keeps the sidebar folded and still knows how it was before the first")
    func takesInARow() {
        let sidebar = MainSidebar()
        sidebar.userSet(.all)
        sidebar.hold(true, animation: nil)
        sidebar.hold(true, animation: nil)
        #expect(sidebar.visibility == .detailOnly)
        sidebar.hold(false, animation: nil)
        #expect(sidebar.visibility == .all)
    }

    @Test("a take holds the sidebar from its count-in through its transcription, and lets go when it lands or fails")
    func holdsWhileTheTakeIsOn() {
        let start = Date()
        let arming = take()
        let recording = take { $0.markCapturing(at: start) }
        let paused = take { $0.markCapturing(at: start); $0.pause(at: start) }
        let transcribing = take { $0.markCapturing(at: start); $0.finish(at: start); $0.transcribing(progress: 0.5) }
        let landed = take { $0.land(entryID: "E") }
        let failed = take { $0.fail("The microphone stopped.") }
        #expect(!SidebarCollapsePolicy.holds(nil))
        #expect(SidebarCollapsePolicy.holds(arming))
        #expect(SidebarCollapsePolicy.holds(recording))
        #expect(SidebarCollapsePolicy.holds(paused))
        #expect(SidebarCollapsePolicy.holds(transcribing))
        #expect(!SidebarCollapsePolicy.holds(landed))
        #expect(!SidebarCollapsePolicy.holds(failed))
    }

    @Test("the model's sidebar folds while the take's session runs and comes back once it is gone")
    func modelOwnsTheSidebar() {
        let model = makeRecordingModel("stage-sidebar")
        #expect(!SidebarCollapsePolicy.holds(model.recording))
        model.installTestTake(source: .microphone)
        let holds = SidebarCollapsePolicy.holds(model.recording)
        model.mainSidebar.hold(holds, animation: nil)
        #expect(model.mainSidebar.visibility == .detailOnly)
        model.endTestTake()
        model.mainSidebar.hold(SidebarCollapsePolicy.holds(model.recording), animation: nil)
        #expect(model.mainSidebar.visibility == .automatic)
    }
}
