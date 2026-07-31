import Foundation
import Testing
@testable import ParolaCore

@Suite("Parakeet download progress")
struct ParakeetProgressTests {
    /// FluidAudio emits per file: 0 → 0.5 while downloading, then 1.0 once compiled.
    private func emissions(files: Int) -> [Double] {
        (0..<files).flatMap { _ in [0.0, 0.5, 1.0] }
    }

    @Test("each file gets its own slice, so the bar can't finish while files remain")
    func perFileSlices() {
        let aggregate = ParakeetTranscriber.FileProgressAggregator(fileCount: 4)
        let reported = emissions(files: 4).map { aggregate.overall($0) }

        #expect(reported.first == 0)
        #expect(reported.last == 1.0)
        // The first file completing must read as a quarter of the job, not all of it.
        #expect(reported[2] == 0.25)
        #expect(reported.dropLast().allSatisfy { $0 < 1.0 })
        #expect(zip(reported, reported.dropFirst()).allSatisfy { $0 <= $1 })
    }

    @Test("a fraction restarting mid-file never drags the bar backwards")
    func monotonic() {
        let aggregate = ParakeetTranscriber.FileProgressAggregator(fileCount: 2)

        #expect(aggregate.overall(0.8) == 0.4)
        #expect(aggregate.overall(0.6) >= 0.4)
        #expect(aggregate.overall(-1) >= 0.4)
        #expect(aggregate.overall(2) == 1.0)
    }
}
