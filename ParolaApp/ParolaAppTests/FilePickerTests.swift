import Foundation
import Testing
import UniformTypeIdentifiers
@testable import Parola

@Suite("TestFilePicker")
struct FilePickerTests {

    private func tempURL(_ name: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(name)
    }

    @Test("queueing an input response returns it from chooseInputFiles and consumes the entry")
    func inputResponseDequeues() async {
        let picker = TestFilePicker()
        let queued = [tempURL("one.wav"), tempURL("two.wav")]
        await picker.queueInputResponse(queued)

        let first = await picker.chooseInputFiles(allowedTypes: [.audio], allowsMultiple: true)
        #expect(first == queued)

        let second = await picker.chooseInputFiles(allowedTypes: [.audio], allowsMultiple: true)
        #expect(second == [])
    }

    @Test("queueing a save response returns it from chooseSaveDestination and consumes the entry")
    func saveResponseDequeues() async {
        let picker = TestFilePicker()
        let destination = tempURL("out.srt")
        await picker.queueSaveResponse(destination)

        let first = await picker.chooseSaveDestination(suggestedName: "out", allowedTypes: [.plainText])
        #expect(first == destination)

        let second = await picker.chooseSaveDestination(suggestedName: "out", allowedTypes: [.plainText])
        #expect(second == nil)
    }

    @Test("an empty input queue returns the empty array, matching user-cancelled semantics")
    func emptyInputQueueReturnsEmpty() async {
        let picker = TestFilePicker()
        let result = await picker.chooseInputFiles(allowedTypes: [.audio], allowsMultiple: false)
        #expect(result == [])
    }

    @Test("an empty save queue returns nil, matching user-cancelled semantics")
    func emptySaveQueueReturnsNil() async {
        let picker = TestFilePicker()
        let result = await picker.chooseSaveDestination(suggestedName: "out", allowedTypes: [.plainText])
        #expect(result == nil)
    }

    @Test("multiple queued input responses come back in FIFO order")
    func inputFIFO() async {
        let picker = TestFilePicker()
        let first = [tempURL("a.wav")]
        let second = [tempURL("b.wav"), tempURL("c.wav")]
        await picker.queueInputResponse(first)
        await picker.queueInputResponse(second)

        #expect(await picker.chooseInputFiles(allowedTypes: [.audio], allowsMultiple: true) == first)
        #expect(await picker.chooseInputFiles(allowedTypes: [.audio], allowsMultiple: true) == second)
    }

    @Test("multiple queued save responses come back in FIFO order")
    func saveFIFO() async {
        let picker = TestFilePicker()
        let first = tempURL("first.srt")
        let second = tempURL("second.srt")
        await picker.queueSaveResponse(first)
        await picker.queueSaveResponse(second)

        #expect(await picker.chooseSaveDestination(suggestedName: "x", allowedTypes: [.plainText]) == first)
        #expect(await picker.chooseSaveDestination(suggestedName: "x", allowedTypes: [.plainText]) == second)
    }

    @Test("a nil save response queues and dequeues as a user-cancelled marker")
    func nilSaveResponseSurvivesRoundTrip() async {
        let picker = TestFilePicker()
        await picker.queueSaveResponse(nil)
        let result = await picker.chooseSaveDestination(suggestedName: "y", allowedTypes: [.plainText])
        #expect(result == nil)
    }
}
