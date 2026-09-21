import Foundation
import Testing
@testable import Parola
import ParolaCore
import ParolaTestSupport

@MainActor
@Suite("File run handler coalescing")
struct FileHandlerCoalescingTests {

    private func makeModel() -> AppModel {
        AppModel(
            skipBootstrap: true,
            defaults: temporaryDefaults(),
            libraryURL: makeTempLibraryURL("coalescing")
        )
    }

    private func settle(_ hops: () -> Int, past mark: Int) async {
        for _ in 0..<200 {
            if hops() > mark { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    @Test("a burst of partials costs one hop and lands the newest text")
    func partialBurstTakesOneHop() async {
        let model = makeModel()
        let coalescer = model.makeFilePartialCoalescer(runToken: model.fileRunGeneration)

        for index in 0..<20 { coalescer.send("partial \(index)") }
        #expect(coalescer.hopCount == 0)

        await settle({ coalescer.hopCount }, past: 0)
        #expect(coalescer.hopCount == 1)
        #expect(model.filePartialText == "partial 19")
    }

    @Test("partials spaced a hop apart each reach the pane")
    func spacedPartialsAllLand() async {
        let model = makeModel()
        let coalescer = model.makeFilePartialCoalescer(runToken: model.fileRunGeneration)
        var seen: [String] = []

        for index in 0..<3 {
            coalescer.send("partial \(index)")
            await settle({ coalescer.hopCount }, past: index)
            seen.append(model.filePartialText)
        }

        #expect(seen == ["partial 0", "partial 1", "partial 2"])
        #expect(coalescer.hopCount == 3)
    }

    @Test("a burst of progress costs one hop and lands the newest fraction")
    func progressBurstTakesOneHop() async {
        let model = makeModel()
        model.mediaDurationSeconds = 100
        let coalescer = model.makeFileProgressCoalescer(runToken: model.fileRunGeneration)

        for second in 1...50 { coalescer.send(Double(second)) }
        #expect(coalescer.hopCount == 0)

        await settle({ coalescer.hopCount }, past: 0)
        #expect(coalescer.hopCount == 1)
        #expect(model.fileTranscribeFraction == 0.5)
    }

    @Test("the whole-percent throttle still hides invisible progress")
    func progressThrottleSurvives() async {
        let model = makeModel()
        model.mediaDurationSeconds = 100
        let coalescer = model.makeFileProgressCoalescer(runToken: model.fileRunGeneration)

        coalescer.send(50)
        await settle({ coalescer.hopCount }, past: 0)
        #expect(model.fileTranscribeFraction == 0.5)

        coalescer.send(50.4)
        await settle({ coalescer.hopCount }, past: 1)
        #expect(coalescer.hopCount == 2)
        #expect(model.fileTranscribeFraction == 0.5)

        coalescer.send(60)
        await settle({ coalescer.hopCount }, past: 2)
        #expect(model.fileTranscribeFraction == 0.6)
    }

    @Test("a burst from an abandoned run never reaches the pane")
    func staleRunBurstIsDropped() async {
        let model = makeModel()
        model.mediaDurationSeconds = 100
        let stale = model.fileRunGeneration - 1
        let partials = model.makeFilePartialCoalescer(runToken: stale)
        let progress = model.makeFileProgressCoalescer(runToken: stale)

        for index in 0..<10 {
            partials.send("partial \(index)")
            progress.send(Double(index))
        }

        await settle({ partials.hopCount }, past: 0)
        await settle({ progress.hopCount }, past: 0)
        #expect(model.filePartialText == "")
        #expect(model.fileTranscribeFraction == nil)
    }

    @Test("the handlers the engine gets are the coalescers")
    func handlersGoThroughTheCoalescer() async {
        let model = makeModel()
        model.mediaDurationSeconds = 100
        let partial = model.makeFilePartialHandler(runToken: model.fileRunGeneration)
        let progress = model.makeFileProgressHandler(runToken: model.fileRunGeneration)

        for index in 0..<10 {
            partial("partial \(index)")
            progress(Double(index) + 1)
        }

        for _ in 0..<200 {
            if model.filePartialText == "partial 9" && model.fileTranscribeFraction == 0.1 { break }
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(model.filePartialText == "partial 9")
        #expect(model.fileTranscribeFraction == 0.1)
    }
}
