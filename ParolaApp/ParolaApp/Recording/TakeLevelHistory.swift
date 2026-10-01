import Foundation

@MainActor
final class TakeLevelHistory {
    nonisolated static let samplesPerSecond: Double = 10

    private(set) var overview: [Float] = []
    private(set) var secondsPerOverviewSample: Double
    private(set) var sampleCount = 0

    private let overviewCapacity: Int
    private var overviewBucket: Float = 0
    private var overviewBucketFill = 0
    private var overviewSamplesPerBucket = 1

    private var recentStorage: [Float]
    private var recentHead = 0
    private var recentFilled = 0

    var recentCapacity: Int { recentStorage.count }

    init(recentSeconds: Double = 48, overviewCapacity: Int = 36_000) {
        self.overviewCapacity = max(2, overviewCapacity)
        self.secondsPerOverviewSample = 1 / Self.samplesPerSecond
        self.recentStorage = Array(repeating: 0, count: max(1, Int(recentSeconds * Self.samplesPerSecond)))
    }

    func append(_ level: Float) {
        let clamped = level.isFinite ? min(1, max(0, level)) : 0
        sampleCount += 1

        recentStorage[recentHead] = clamped
        recentHead = (recentHead + 1) % recentStorage.count
        recentFilled = min(recentFilled + 1, recentStorage.count)

        overviewBucket = max(overviewBucket, clamped)
        overviewBucketFill += 1
        guard overviewBucketFill >= overviewSamplesPerBucket else { return }
        overview.append(overviewBucket)
        overviewBucket = 0
        overviewBucketFill = 0
        if overview.count >= overviewCapacity {
            halveOverview()
        }
    }

    func recent(_ count: Int) -> [Float] {
        guard count > 0 else { return [] }
        let available = min(count, recentFilled)
        let padding = count - available
        var result = Array(repeating: Float(0), count: padding)
        guard available > 0 else { return result }
        let start = (recentHead - available + recentStorage.count * 2) % recentStorage.count
        for offset in 0..<available {
            result.append(recentStorage[(start + offset) % recentStorage.count])
        }
        return result
    }

    func pooled(into bars: Int) -> [Float] {
        guard bars > 0, !overview.isEmpty else { return [] }
        guard overview.count > bars else { return overview }
        let perBar = Double(overview.count) / Double(bars)
        return (0..<bars).map { bar in
            let from = Int(Double(bar) * perBar)
            let to = max(from + 1, min(overview.count, Int(Double(bar + 1) * perBar)))
            var loudest: Float = 0
            for index in from..<to { loudest = max(loudest, overview[index]) }
            return loudest
        }
    }

    private func halveOverview() {
        var halved: [Float] = []
        halved.reserveCapacity((overview.count + 1) / 2)
        var index = 0
        while index < overview.count {
            let next = index + 1 < overview.count ? overview[index + 1] : overview[index]
            halved.append(max(overview[index], next))
            index += 2
        }
        overview = halved
        secondsPerOverviewSample *= 2
        overviewSamplesPerBucket *= 2
    }
}
