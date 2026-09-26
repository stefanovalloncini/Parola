import Foundation
import Observation
import ParolaCore

/// One job's bar. Each row observes its own box, so a tick redraws that bar and nothing else.
@MainActor
@Observable
final class BatchJobProgress {
    fileprivate(set) var fraction: Double = 0
}

/// Per-job progress, kept out of `batchJobs` so a tick never touches the list the pages and menus read.
@MainActor
final class BatchProgressBoard {
    private var boxes: [BatchJob.ID: BatchJobProgress] = [:]

    /// Made on first read, so a row that draws before the first tick still observes the box the tick lands in.
    func box(for id: BatchJob.ID) -> BatchJobProgress {
        if let box = boxes[id] { return box }
        let box = BatchJobProgress()
        boxes[id] = box
        return box
    }

    func fraction(for id: BatchJob.ID) -> Double {
        box(for: id).fraction
    }

    /// A bar never walks backwards.
    func advance(_ id: BatchJob.ID, to fraction: Double) {
        let box = box(for: id)
        if fraction > box.fraction { box.fraction = fraction }
    }

    func reset(_ id: BatchJob.ID) {
        guard let box = boxes[id], box.fraction != 0 else { return }
        box.fraction = 0
    }

    func retain(_ ids: Set<BatchJob.ID>) {
        guard boxes.keys.contains(where: { !ids.contains($0) }) else { return }
        boxes = boxes.filter { ids.contains($0.key) }
    }
}
