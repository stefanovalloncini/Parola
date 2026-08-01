import AVFoundation
import os

/// Writes a live capture's converted chunks to its file, latching the first write failure so a
/// take that stopped landing on disk is reported instead of read back as silence.
// Unchecked Sendable: `writeChunk` runs only on the capture's own serialized callback path; the latches are lock-guarded so a tap thread can report a drop.
final class CaptureFileWriter: @unchecked Sendable {
    private let writeChunk: (AVAudioPCMBuffer) throws -> Void
    private let latchedFailure = OSAllocatedUnfairLock<String?>(initialState: nil)
    private let drops = OSAllocatedUnfairLock<Int>(initialState: 0)

    init(file: AVAudioFile) {
        self.writeChunk = { [file] buffer in try file.write(from: buffer) }
    }

    init(writeChunk: @escaping (AVAudioPCMBuffer) throws -> Void) {
        self.writeChunk = writeChunk
    }

    var failure: String? {
        latchedFailure.withLock { $0 }
    }

    var droppedChunks: Int {
        drops.withLock { $0 }
    }

    /// A backlog drop leaves a gap in the take but keeps everything already on disk, so it never fails the recording.
    func noteDrop() {
        drops.withLock { $0 += 1 }
    }

    func write(_ buffer: AVAudioPCMBuffer) {
        guard failure == nil else { return }
        do {
            try writeChunk(buffer)
        } catch {
            fail("could not write the recording to disk (\(error.localizedDescription))")
        }
    }

    func fail(_ reason: String) {
        latchedFailure.withLock { if $0 == nil { $0 = reason } }
    }
}
