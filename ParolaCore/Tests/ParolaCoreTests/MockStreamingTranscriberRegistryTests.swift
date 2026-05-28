import Testing
@testable import ParolaCore

@Suite("Mock streaming registry")
struct MockStreamingTranscriberRegistryTests {
    @Test("install then resolve, clear removes it")
    func installResolveClear() async {
        let reg = MockStreamingTranscriberRegistry()
        #expect(await reg.resolve() == nil)
        await reg.install(MockTranscriberResponse(partials: ["x"]))
        #expect(await reg.resolve() != nil)
        await reg.clear()
        #expect(await reg.resolve() == nil)
    }
}
