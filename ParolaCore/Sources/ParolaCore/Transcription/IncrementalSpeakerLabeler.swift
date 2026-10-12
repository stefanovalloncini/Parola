import Foundation
import FluidAudio
import os

/// Labels confirmed streaming segments with session-local speakers ("Speaker 1..N").
/// Each confirmed segment's audio window is embedded with FluidAudio's speaker model and
/// greedily matched against running per-speaker centroids; labels never change once emitted.
public actor IncrementalSpeakerLabeler: StreamingSpeakerLabeler {
    static let minWindowSeconds: Double = 0.5
    static let maxWindowSamples = 160_000

    private let embedWindow: (ArraySlice<Float>) async throws -> [Float]
    private let finished: (@Sendable () -> Void)?
    private var tracker: SpeakerCentroidTracker

    init(
        maxAssignmentDistance: Float = SpeakerCentroidTracker.defaultMaxAssignmentDistance,
        embedWindow: sending @escaping (ArraySlice<Float>) async throws -> [Float],
        finished: (@Sendable () -> Void)? = nil
    ) {
        self.embedWindow = embedWindow
        self.finished = finished
        self.tracker = SpeakerCentroidTracker(maxAssignmentDistance: maxAssignmentDistance)
    }

    deinit { finished?() }

    public func labelSpeaker(
        for segment: TranscriptSegment,
        audioWindow: ArraySlice<Float>,
        windowStartTime: TimeInterval,
        sampleRate: Double
    ) async -> String? {
        guard sampleRate == 16_000 else { return nil }
        guard Double(audioWindow.count) >= Self.minWindowSeconds * sampleRate else { return nil }
        // FluidAudio's extractor buffer holds 10 s; longer input overruns it (see EmbeddingExtractor.fillWaveformBuffer).
        let window = audioWindow.prefix(Self.maxWindowSamples)
        guard let embedding = await embedUnlessCancelled(window) else { return nil }
        return tracker.label(for: embedding)
    }
}

extension IncrementalSpeakerLabeler {
    /// Gives up on the embedding when the caller is cancelled, so a Cancel doesn't wait behind a cold model load.
    private func embedUnlessCancelled(_ window: ArraySlice<Float>) async -> [Float]? {
        guard !Task.isCancelled else { return nil }
        let outcome = EmbeddingOutcome()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                outcome.install(continuation)
                Task { outcome.finish(try? await embedWindow(window)) }
            }
        } onCancel: {
            outcome.finish(nil)
        }
    }

    /// True when the FluidAudio diarizer models are already on disk under the model store.
    public static func modelsInstalled(store: ModelStore = .shared) -> Bool {
        let dir = modelsDirectory(store: store)
        return ModelNames.Diarizer.requiredModels.allSatisfy {
            FileManager.default.fileExists(atPath: dir.appendingPathComponent($0).path)
        }
    }

    /// Downloads the FluidAudio diarizer models into the model store. Idempotent.
    public static func downloadModels(store: ModelStore = .shared) async throws {
        _ = try await DiarizerModels.download(to: modelsDirectory(store: store))
    }

    /// A labeler for one take that embeds with the process-wide models. The load starts now and the first label waits for it,
    /// so a take opens its microphone without the load and keeps the models for the next one.
    public static func sharedInstalled() -> IncrementalSpeakerLabeler {
        labeler(using: .shared)
    }

    /// Builds a labeler from the models already on disk. Never downloads.
    public static func loadInstalled(store: ModelStore = .shared) async throws -> IncrementalSpeakerLabeler {
        let models = store === ModelStore.shared ? SpeakerLabelerModels.shared : SpeakerLabelerModels(store: store)
        await models.beginTake()
        do {
            try await models.ensureLoaded()
        } catch {
            await models.endTake()
            throw error
        }
        return IncrementalSpeakerLabeler(
            embedWindow: { window in try await models.embed(window) },
            finished: { Task { await models.endTake() } }
        )
    }

    static func labeler(using models: SpeakerLabelerModels) -> IncrementalSpeakerLabeler {
        let begun = Task { await models.beginTake() }
        return IncrementalSpeakerLabeler(
            embedWindow: { window in try await models.embed(window) },
            finished: { Task { await begun.value; await models.endTake() } }
        )
    }

    // DiarizerModels.download resolves its target as parent-of-the-passed-directory + Repo.folderName,
    // so the last path component here must stay Repo.diarizer.folderName.
    static func modelsDirectory(store: ModelStore) -> URL {
        store.directory
            .appendingPathComponent("models", isDirectory: true)
            .appendingPathComponent("FluidInference", isDirectory: true)
            .appendingPathComponent(Repo.diarizer.folderName, isDirectory: true)
    }
}

struct SpeakerCentroidTracker {
    static let defaultMaxAssignmentDistance: Float = 0.65

    let maxAssignmentDistance: Float
    private var centroids: [[Float]] = []
    private var counts: [Int] = []

    init(maxAssignmentDistance: Float = Self.defaultMaxAssignmentDistance) {
        self.maxAssignmentDistance = maxAssignmentDistance
    }

    mutating func label(for embedding: [Float]) -> String? {
        guard isUsable(embedding) else { return nil }
        var best: (index: Int, distance: Float)?
        for (index, centroid) in centroids.enumerated() {
            guard let distance = Self.cosineDistance(centroid, embedding) else { continue }
            if best == nil || distance < best!.distance {
                best = (index, distance)
            }
        }
        if let best, best.distance <= maxAssignmentDistance {
            absorb(embedding, into: best.index)
            return "Speaker \(best.index + 1)"
        }
        centroids.append(embedding)
        counts.append(1)
        return "Speaker \(centroids.count)"
    }

    private mutating func absorb(_ embedding: [Float], into index: Int) {
        let count = Float(counts[index])
        for i in centroids[index].indices {
            centroids[index][i] = (centroids[index][i] * count + embedding[i]) / (count + 1)
        }
        counts[index] += 1
    }

    private func isUsable(_ embedding: [Float]) -> Bool {
        guard !embedding.isEmpty, embedding.allSatisfy(\.isFinite) else { return false }
        return embedding.contains { abs($0) > 1e-6 }
    }

    static func cosineDistance(_ a: [Float], _ b: [Float]) -> Float? {
        guard a.count == b.count, !a.isEmpty else { return nil }
        var dot: Float = 0
        var normA: Float = 0
        var normB: Float = 0
        for i in a.indices {
            dot += a[i] * b[i]
            normA += a[i] * a[i]
            normB += b[i] * b[i]
        }
        guard normA > 0, normB > 0 else { return nil }
        return 1 - dot / (normA.squareRoot() * normB.squareRoot())
    }
}

/// Hands the first of an embedding or a cancellation to the waiting caller; the other is dropped.
private final class EmbeddingOutcome: Sendable {
    private struct State {
        var continuation: CheckedContinuation<[Float]?, Never>?
        var result: [Float]??
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    func install(_ continuation: CheckedContinuation<[Float]?, Never>) {
        let ready = state.withLock { state -> [Float]?? in
            if let result = state.result { return result }
            state.continuation = continuation
            return nil
        }
        if let ready { continuation.resume(returning: ready) }
    }

    func finish(_ embedding: [Float]?) {
        let waiting = state.withLock { state -> CheckedContinuation<[Float]?, Never>? in
            guard state.result == nil else { return nil }
            state.result = .some(embedding)
            defer { state.continuation = nil }
            return state.continuation
        }
        waiting?.resume(returning: embedding)
    }
}
