import Testing
@testable import ParolaCore

@Suite("Mock streaming registry")
struct MockStreamingTranscriberRegistryTests {
    @Test("install then resolve, clear removes it")
    func installResolveClear() {
        let reg = MockStreamingTranscriberRegistry()
        #expect(reg.resolve() == nil)
        reg.install(MockTranscriberResponse(partials: ["x"]))
        #expect(reg.resolve() != nil)
        reg.clear()
        #expect(reg.resolve() == nil)
    }
}
