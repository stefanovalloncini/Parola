import AVFoundation
import Foundation

/// Rewrites a WAV's size fields from the bytes it really holds, for a take whose writer never closed it.
public enum WAVHeaderRepair {
    /// True when the file opens with audio in it, after fixing its RIFF and data sizes if it didn't.
    @discardableResult
    public static func makeReadable(_ url: URL) -> Bool {
        if hasAudio(url) { return true }
        guard rewriteSizes(url) else { return false }
        return hasAudio(url)
    }

    private static func hasAudio(_ url: URL) -> Bool {
        guard let file = try? AVAudioFile(forReading: url) else { return false }
        return file.length > 0
    }

    private static func rewriteSizes(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forUpdating: url) else { return false }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd(), size > 12, size <= UInt64(UInt32.max),
              let head = read(handle, at: 0, count: 12),
              head.prefix(4) == Data("RIFF".utf8), head.suffix(4) == Data("WAVE".utf8) else { return false }
        var offset: UInt64 = 12
        var blockAlign: UInt64 = 1
        while offset + 8 <= size, let header = read(handle, at: offset, count: 8) {
            let body = offset + 8
            let declared = UInt64(littleEndian32(header.suffix(4)))
            switch String(decoding: header.prefix(4), as: UTF8.self) {
            case "fmt ":
                if let align = read(handle, at: body + 12, count: 2) {
                    blockAlign = max(1, UInt64(UInt16(align[align.startIndex]) | UInt16(align[align.startIndex + 1]) << 8))
                }
            case "data":
                let audioBytes = (size - body) / blockAlign * blockAlign
                guard audioBytes > 0 else { return false }
                return write(handle, UInt32(audioBytes), at: body - 4)
                    && write(handle, UInt32(body + audioBytes - 8), at: 4)
            default:
                break
            }
            offset = body + declared + (declared & 1)
        }
        return false
    }

    private static func read(_ handle: FileHandle, at offset: UInt64, count: Int) -> Data? {
        guard (try? handle.seek(toOffset: offset)) != nil,
              let data = try? handle.read(upToCount: count), data.count == count else { return nil }
        return data
    }

    private static func write(_ handle: FileHandle, _ value: UInt32, at offset: UInt64) -> Bool {
        var little = value.littleEndian
        let data = Data(bytes: &little, count: 4)
        return (try? handle.seek(toOffset: offset)) != nil && (try? handle.write(contentsOf: data)) != nil
    }

    private static func littleEndian32(_ bytes: Data) -> UInt32 {
        bytes.enumerated().reduce(0) { $0 | UInt32($1.element) << (8 * UInt32($1.offset)) }
    }
}
