import CoreGraphics

/// A meter bar's height: linear in dB across speech, resting below −33 dBFS and full from −6 dBFS.
enum LevelBars {
    /// The meter reads dBFS over this floor: its 0…1 level is (dBFS + 55) / 55.
    static let meterFloorDBFS: Float = -55
    static let restDBFS: Float = -33
    static let fullDBFS: Float = -6

    static func fraction(for level: Float) -> CGFloat {
        let clamped = level.isFinite ? min(1, max(0, level)) : 0
        let dBFS = meterFloorDBFS * (1 - clamped)
        return CGFloat(min(1, max(0, (dBFS - restDBFS) / (fullDBFS - restDBFS))))
    }

    static func height(for level: Float, idle: CGFloat, max: CGFloat) -> CGFloat {
        idle + (max - idle) * fraction(for: level)
    }
}
