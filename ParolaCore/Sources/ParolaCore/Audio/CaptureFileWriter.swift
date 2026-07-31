import AVFoundation
import os

/// Writes a live capture's converted chunks to its file and latches the first failure, so a
/// take that stopped landing on disk is reported at `prepare()` instead of read back as silence.
// Unchecked Sendable: `writeChunk` runs only on the capture's own serialized callback path,
// and the failure latch is lock-guarded so a tap thread can report a drop.
final class CaptureFileWriter: @unchecked Sendable {
    private let writeChunk: (AVAudioPCMBuffer) throws -> Void
    private let latchedFailure = OSAllocatedUnfairLock<String?>(initialState: nil)

    init(file: AVAudioFile) {
        self.writeChunk = { [file] buffer in try file.write(from: buffer) }
    }

    init(writeChunk: @escaping (AVAudioPCMBuffer) throws -> Void) {
        self.writeChunk = writeChunk
    }

    var failure: String? {
        latchedFailure.withLock { $0 }
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
