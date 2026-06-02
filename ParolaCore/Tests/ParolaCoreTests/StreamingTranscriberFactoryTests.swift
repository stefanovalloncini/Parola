import Testing
@testable import ParolaCore

@Suite("Streaming transcriber factory")
struct StreamingTranscriberFactoryTests {
    @Test("returns mock when one is installed, real session otherwise")
    func selectsBackend() {
        MockStreamingTranscriberRegistry.shared.clear()
        let real = StreamingTranscriberFactory.make()
        #expect(real is StreamingTranscriptionSession)
        MockStreamingTranscriberRegistry.shared.install(MockTranscriberResponse(partials: ["x"]))
        let mock = StreamingTranscriberFactory.make()
        #expect(mock is MockStreamingTranscriber)
        MockStreamingTranscriberRegistry.shared.clear()
    }
}
