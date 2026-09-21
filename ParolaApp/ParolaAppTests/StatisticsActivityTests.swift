import Foundation
import Testing
import ParolaCore
@testable import Parola

@Suite("Statistics activity axis")
struct StatisticsActivityTests {
    private let english = Locale(identifier: "en_US")

    @Test("under three hours the axis counts minutes, from three hours it counts hours")
    func unitFollowsTheTallestBar() {
        #expect(ActivityAxis(maxMinutes: 45).unit == .minutes)
        #expect(ActivityAxis(maxMinutes: 179).unit == .minutes)
        #expect(ActivityAxis(maxMinutes: 180).unit == .hours)
        #expect(ActivityAxis(maxMinutes: 5_000).unit == .hours)
    }

    @Test("the ticks start at zero, reach past the tallest bar and never exceed four")
    func ticksCoverTheData() {
        #expect(ActivityAxis(maxMinutes: 45).ticks == [0, 15, 30, 45])
        #expect(ActivityAxis(maxMinutes: 170).ticks == [0, 60, 120, 180])
        #expect(ActivityAxis(maxMinutes: 200).ticks == [0, 90, 180, 270])
        #expect(ActivityAxis(maxMinutes: 600).ticks == [0, 300, 600])
        for max in stride(from: 0.0, through: 100_000, by: 7.3) {
            let axis = ActivityAxis(maxMinutes: max)
            #expect(axis.ticks.first == 0)
            #expect(axis.ticks.count <= 4 && axis.ticks.count >= 2, "\(max)")
            #expect(axis.top >= max, "\(max)")
            #expect(axis.ticks == axis.ticks.sorted())
        }
    }

    @Test("an empty chart still has an axis to draw")
    func emptyChartKeepsAnAxis() {
        let axis = ActivityAxis(maxMinutes: 0)
        #expect(axis.unit == .minutes)
        #expect(axis.ticks.count >= 2)
        #expect(axis.top > 0)
    }

    @Test("labels use one unit per chart and stay short")
    func labelsAreShortAndUniform() {
        let minutes = ActivityAxis(maxMinutes: 170)
        #expect(minutes.ticks.dropFirst().map { minutes.label($0, locale: english) } == ["60 min", "120 min", "180 min"])
        let hours = ActivityAxis(maxMinutes: 200)
        #expect(hours.ticks.dropFirst().map { hours.label($0, locale: english) } == ["1.5 h", "3 h", "4.5 h"])
        for max in stride(from: 0.0, through: 100_000, by: 11.9) {
            let axis = ActivityAxis(maxMinutes: max)
            for tick in axis.ticks {
                let label = axis.label(tick, locale: english)
                #expect(label.count <= 7, "\(max): \(label)")
                #expect(label.hasSuffix(axis.unit == .minutes ? " min" : " h"), "\(max): \(label)")
            }
        }
    }
}
