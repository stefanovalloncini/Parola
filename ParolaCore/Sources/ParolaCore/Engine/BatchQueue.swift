import Foundation
import os

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
    /// The library entry the result was saved as; once it is set, the entry holds the transcript.
    public var entryID: String?
    /// How many segments the result has, kept when the transcript itself is let go.
    public var segmentCount: Int?
    /// The file's digest as the duplicate check took it, for the library add to reuse.
    public var sourceDigest: String?

    public init(
        id: UUID = UUID(),
        url: URL,
        status: Status = .pending,
        transcript: Transcript? = nil,
        error: String? = nil,
        progress: Double = 0,
        entryID: String? = nil,
        segmentCount: Int? = nil,
        sourceDigest: String? = nil
    ) {
        self.id = id
        self.url = url
        self.status = status
        self.transcript = transcript
        self.error = error
        self.progress = progress
        self.entryID = entryID
        self.segmentCount = segmentCount
        self.sourceDigest = sourceDigest
    }

    public var displayName: String { url.deletingPathExtension().lastPathComponent }
}

public enum BatchEvent: Sendable {
    case started(jobID: UUID)
    case progress(jobID: UUID, fraction: Double)
    case completed(jobID: UUID, transcript: Transcript)
    /// `reason` is the line the CLI prints; `error` lets a front end word the failure itself.
    case failed(jobID: UUID, reason: String, error: (any Error)?)
    case cancelled(jobID: UUID)
    case finished

    public static func failed(jobID: UUID, reason: String) -> BatchEvent {
        .failed(jobID: jobID, reason: reason, error: nil)
    }
}

/// Sequentially transcribes a list of files through a single ``TranscriptionSession``.
///
/// One worker on purpose: WhisperKit only loads one model at a time, so keeping the cache
/// warm beats lighting up two copies in parallel.
public actor BatchQueue {
    private let session: TranscriptionSession
    private let features: FeatureSet
    private let durationProbeDeadline: Duration
    private let clock: any Clock<Duration>
    private let durationProbe: @Sendable (URL) async -> Double?
    private var jobInFlight = false

    public init(session: TranscriptionSession = TranscriptionSession(), features: FeatureSet = .resolve()) {
        self.init(session: session, features: features, durationProbeDeadline: FileReadDeadline.header) { url in
            await FileAudioSource(url: url).estimatedDuration()
        }
    }

    init(
        session: TranscriptionSession,
        features: FeatureSet,
        durationProbeDeadline: Duration,
        clock: any Clock<Duration> = ContinuousClock(),
        durationProbe: @escaping @Sendable (URL) async -> Double?
    ) {
        self.session = session
        self.features = features
        self.durationProbeDeadline = durationProbeDeadline
        self.clock = clock
        self.durationProbe = durationProbe
    }

    /// `stillQueued` is asked as each job's turn comes; a job it turns down is skipped without an event.
    public func process(
        jobs: [BatchJob],
        options: TranscriptionOptions,
        stillQueued: @escaping @Sendable (UUID) async -> Bool = { _ in true }
    ) -> AsyncStream<BatchEvent> {
        guard features.isEnabled(.batch) else {
            ParolaLog.notice(
                .batch, "batch refused: batch disabled",
                [.count: .int(jobs.count)]
            )
            return AsyncStream { continuation in
                let reason = ParolaError.featureDisabled(.batch).description
                for job in jobs { continuation.yield(.failed(jobID: job.id, reason: reason)) }
                continuation.yield(.finished)
                continuation.finish()
            }
        }
        return AsyncStream { continuation in
            let processingTask = Task {
                await self.run(jobs: jobs, options: options, stillQueued: stillQueued, continuation: continuation)
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
        stillQueued: @Sendable (UUID) async -> Bool,
        continuation: AsyncStream<BatchEvent>.Continuation
    ) async {
        ParolaLog.info(.batch, "batch starting", [.count: .int(jobs.count)])
        var completed = 0
        var failed = 0
        var cancelled = 0
        for job in jobs {
            if Task.isCancelled {
                cancelled += 1
                continuation.yield(.cancelled(jobID: job.id))
                continue
            }
            guard await stillQueued(job.id) else {
                ParolaLog.info(.batch, "job skipped: no longer queued", [.job: .id(job.id)])
                continue
            }
            continuation.yield(.started(jobID: job.id))
            let startedAt = ContinuousClock.now
            do {
                let source = FileAudioSource(url: job.url)
                // AVFoundation's asset queue can park on a file that never opens, and one parked load stalls the rest.
                let duration = await AsyncTimeout.run(durationProbeDeadline, clock: clock) { [durationProbe, url = job.url] in
                    await durationProbe(url)
                } ?? nil
                let forwarder = Self.progressForwarder(
                    jobID: job.id,
                    duration: duration,
                    continuation: continuation
                )
                // Only set once the session call is the very next thing: cancelOwnInFlight would
                // otherwise cancel whatever else the shared session is running.
                jobInFlight = true
                defer { jobInFlight = false }
                let transcript = try await session.transcribe(
                    source: source,
                    options: options,
                    progressHandler: forwarder
                )
                completed += 1
                continuation.yield(.completed(jobID: job.id, transcript: transcript))
            } catch is CancellationError {
                cancelled += 1
                ParolaLog.info(.batch, "job cancelled", [.job: .id(job.id)])
                continuation.yield(.cancelled(jobID: job.id))
            } catch {
                failed += 1
                ParolaLog.error(
                    .batch, "job failed",
                    [
                        .job: .id(job.id),
                        .elapsed: .duration(startedAt.duration(to: .now)),
                        .error: .error(error),
                    ]
                )
                continuation.yield(.failed(jobID: job.id, reason: String(describing: error), error: error))
            }
        }
        ParolaLog.info(
            .batch, "batch finished",
            [.completed: .int(completed), .failed: .int(failed), .cancelled: .int(cancelled)]
        )
        continuation.yield(.finished)
        continuation.finish()
    }

    /// Throttled to whole percents; a file whose duration we can't read gets no handler at all.
    private static func progressForwarder(
        jobID: UUID,
        duration: Double?,
        continuation: AsyncStream<BatchEvent>.Continuation
    ) -> (@Sendable (Double) -> Void)? {
        guard let duration, duration > 0 else { return nil }
        let lastPercent = OSAllocatedUnfairLock(initialState: -1)
        return { seconds in
            let fraction = min(1, max(0, seconds / duration))
            let percent = Int(fraction * 100)
            let advanced = lastPercent.withLock { last in
                guard percent > last else { return false }
                last = percent
                return true
            }
            guard advanced else { return }
            continuation.yield(.progress(jobID: jobID, fraction: fraction))
        }
    }

    // The session is shared; a stale termination must not cancel work it now runs for someone else.
    private func cancelOwnInFlight() async {
        guard jobInFlight else { return }
        await session.cancelInFlight()
    }
}
