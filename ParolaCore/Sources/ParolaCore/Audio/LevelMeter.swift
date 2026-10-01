import Foundation
import os

/// How loud a live capture is, written once per buffer from the capture's own thread and read by a meter
/// when it draws. Nothing is pushed to the reader, so a take costs the main thread nothing between frames.
public final class LevelMeter: Sendable {
    /// A buffer at or above this counts as sound; a reader can rest its display clock while none arrives.
    public static let soundFloor: Float = 0.05

    private struct Reading {
        var level: Float = 0
        var peak: Float = 0
        var lastSound: ContinuousClock.Instant?
        var firstReadingAt: ContinuousClock.Instant?
        var lastReadingAt: ContinuousClock.Instant?
    }

    private let reading = OSAllocatedUnfairLock(initialState: Reading())

    public init() {}

    /// `level` is a 0...1 amplitude, as `AudioLevel` maps a buffer.
    public func record(_ level: Float) {
        let clamped = level.isFinite ? min(1, max(0, level)) : 0
        let now = ContinuousClock.now
        let soundNow: ContinuousClock.Instant? = clamped >= Self.soundFloor ? now : nil
        reading.withLock { reading in
            reading.level = clamped
            reading.peak = max(reading.peak, clamped)
            if let soundNow { reading.lastSound = soundNow }
            if reading.firstReadingAt == nil { reading.firstReadingAt = now }
            reading.lastReadingAt = now
        }
    }

    /// The most recent buffer's level.
    public var level: Float {
        reading.withLock(\.level)
    }

    /// The loudest buffer since the previous call, so a reader slower than the capture keeps its peaks.
    public func takePeak() -> Float {
        reading.withLock { reading in
            let peak = reading.peak
            reading.peak = reading.level
            return peak
        }
    }

    /// When a buffer last reached `soundFloor`; nil before any did.
    public var lastSound: ContinuousClock.Instant? {
        reading.withLock(\.lastSound)
    }

    /// When this meter's first reading came in, silent or not; nil before any did.
    public var firstReadingAt: ContinuousClock.Instant? {
        reading.withLock(\.firstReadingAt)
    }

    /// When the latest reading came in, silent or not, so a reader can tell a capture that stopped from one gone quiet.
    public var lastReadingAt: ContinuousClock.Instant? {
        reading.withLock(\.lastReadingAt)
    }

    public func reset() {
        reading.withLock { $0 = Reading() }
    }
}
