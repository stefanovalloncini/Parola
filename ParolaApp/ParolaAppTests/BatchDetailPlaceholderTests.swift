import Foundation
import Testing
@testable import Parola

@Suite("BatchDetailPlaceholder")
struct BatchDetailPlaceholderTests {
    @Test("a running batch shows the progress spinner, even with completed jobs")
    func runningWins() {
        #expect(BatchDetailPlaceholder(isRunning: true, hasCompletedJob: false) == .running)
        #expect(BatchDetailPlaceholder(isRunning: true, hasCompletedJob: true) == .running)
    }

    @Test("a finished batch with a completed job invites picking a file")
    func finishedWithCompletedJob() {
        #expect(BatchDetailPlaceholder(isRunning: false, hasCompletedJob: true) == .selectFile)
    }

    @Test("a finished batch with no completed job reports no transcripts")
    func finishedAllFailed() {
        #expect(BatchDetailPlaceholder(isRunning: false, hasCompletedJob: false) == .noTranscripts)
    }
}
