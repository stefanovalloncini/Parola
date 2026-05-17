import Foundation
import Testing
@testable import ParolaCore

@Suite("Batch queue")
struct BatchQueueTests {
    @Test("BatchJob round-trips through Codable")
    func codable() throws {
        let url = URL(fileURLWithPath: "/tmp/whatever.wav")
        let job = BatchJob(url: url, status: .done, progress: 1)
        let data = try JSONEncoder().encode(job)
        let decoded = try JSONDecoder().decode(BatchJob.self, from: data)
        #expect(decoded == job)
    }

    @Test("processing jobs against missing files reports failures in order")
    func failuresInOrder() async {
        let jobs = [
            BatchJob(url: URL(fileURLWithPath: "/tmp/no-such-file-1.wav")),
            BatchJob(url: URL(fileURLWithPath: "/tmp/no-such-file-2.wav")),
        ]
        let queue = BatchQueue()
        let events = await queue.process(jobs: jobs, options: TranscriptionOptions(model: "openai_whisper-tiny"))

        var failedOrder: [UUID] = []
        var sawFinished = false
        for await event in events {
            switch event {
            case .failed(let id, _): failedOrder.append(id)
            case .finished: sawFinished = true
            default: break
            }
        }
        #expect(sawFinished)
        #expect(failedOrder == jobs.map(\.id))
    }

    @Test("BatchEvent.cancelled exists alongside .failed in the enum surface")
    func cancelledCase() {
        let id = UUID()
        let cancelled = BatchEvent.cancelled(jobID: id)
        switch cancelled {
        case .cancelled(let jobID):
            #expect(jobID == id)
        default:
            Issue.record("expected .cancelled")
        }
    }
}
