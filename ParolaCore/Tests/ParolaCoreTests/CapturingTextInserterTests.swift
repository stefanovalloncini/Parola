import Testing
@testable import ParolaDictation

@Suite("Capturing text inserter")
struct CapturingTextInserterTests {
    @Test("fresh store is empty")
    func freshStoreIsEmpty() {
        let store = CapturedInsertionStore()
        #expect(store.last() == nil)
        #expect(store.all() == [])
    }

    @Test("insert records text in order")
    func insertRecordsTextInOrder() async {
        let store = CapturedInsertionStore()
        let inserter = CapturingTextInserter(store: store)
        await inserter.insert("a")
        await inserter.insert("b")
        #expect(store.last() == "b")
        #expect(store.all() == ["a", "b"])
    }

    @Test("clear empties the buffer")
    func clearEmptiesBuffer() async {
        let store = CapturedInsertionStore()
        let inserter = CapturingTextInserter(store: store)
        await inserter.insert("x")
        store.clear()
        #expect(store.last() == nil)
        #expect(store.all() == [])
    }
}
