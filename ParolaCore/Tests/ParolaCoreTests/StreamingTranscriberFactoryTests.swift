import Testing
@testable import ParolaCore

@Suite("Streaming transcriber factory")
struct StreamingTranscriberFactoryTests {
    @Test("returns mock when one is installed, real session otherwise")
    func selectsBackend() async {
        await MockStreamingTranscriberRegistry.shared.clear()
        let real = await StreamingTranscriberFactory.make()
        #expect(real is StreamingTranscriptionSession)
        await MockStreamingTranscriberRegistry.shared.install(MockTranscriberResponse(partials: ["x"]))
        let mock = await StreamingTranscriberFactory.make()
        #expect(mock is MockStreamingTranscriber)
        await MockStreamingTranscriberRegistry.shared.clear()
    }
}
