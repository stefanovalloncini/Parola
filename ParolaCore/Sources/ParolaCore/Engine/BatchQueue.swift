import Foundation

public struct BatchJob: Identifiable, Sendable, Hashable, Codable {
    public enum Status: String, Sendable, Codable {
        case pending
        case transcribing
        case done
        case failed
        case cancelled
    }

    public var id: UUID
    public var url: URL
    public var status: Status
    public var transcript: Transcript?
    public var error: String?
    public var progress: Double

    public init(
        id: UUID = UUID(),
        url: URL,
        status: Status = .pending,
        transcript: Transcript? = nil,
        error: String? = nil,
        progress: Double = 0
    ) {
        self.id = id
        self.url = url
        self.status = status
        self.transcript = transcript
        self.error = error
        self.progress = progress
    }

    public var displayName: String { url.deletingPathExtension().lastPathComponent }
}

public enum BatchEvent: Sendable {
    case started(jobID: UUID)
    case completed(jobID: UUID, transcript: Transcript)
    case failed(jobID: UUID, reason: String)
    case cancelled(jobID: UUID)
    case finished
}

/// Sequentially transcribes a list of files through a single ``TranscriptionSession``.
///
/// One worker on purpose: WhisperKit only loads one model at a time, so keeping the cache
/// warm beats lighting up two copies in parallel.
public actor BatchQueue {
    private let session: TranscriptionSession
    private let features: FeatureSet
    private var jobInFlight = false

    public init(session: TranscriptionSession = TranscriptionSession(), features: FeatureSet = .resolve()) {
        self.session = session
        self.features = features
    }

    public func process(
        jobs: [BatchJob],
        options: TranscriptionOptions
    ) -> AsyncStream<BatchEvent> {
        guard features.isEnabled(.batch) else {
            return AsyncStream { continuation in
                let reason = ParolaError.featureDisabled(.batch).description
                for job in jobs { continuation.yield(.failed(jobID: job.id, reason: reason)) }
                continuation.yield(.finished)
                continuation.finish()
            }
        }
        return AsyncStream { continuation in
            let processingTask = Task {
                await self.run(jobs: jobs, options: options, continuation: continuation)
            }
            continuation.onTermination = { _ in
                processingTask.cancel()
                Task { await self.cancelOwnInFlight() }
            }
        }
    }

    private func run(
        jobs: [BatchJob],
        options: TranscriptionOptions,
        continuation: AsyncStream<BatchEvent>.Continuation
    ) async {
        for job in jobs {
            if Task.isCancelled {
                continuation.yield(.cancelled(jobID: job.id))
                continue
            }
            continuation.yield(.started(jobID: job.id))
            do {
                jobInFlight = true
                defer { jobInFlight = false }
                let transcript = try await session.transcribe(
                    source: FileAudioSource(url: job.url),
                    options: options
                )
                continuation.yield(.completed(jobID: job.id, transcript: transcript))
            } catch is CancellationError {
                continuation.yield(.cancelled(jobID: job.id))
            } catch {
                continuation.yield(.failed(jobID: job.id, reason: String(describing: error)))
            }
        }
        continuation.yield(.finished)
        continuation.finish()
    }

    // The session is shared; a stale termination must not cancel work it now runs for someone else.
    private func cancelOwnInFlight() async {
        guard jobInFlight else { return }
        await session.cancelInFlight()
    }
}
