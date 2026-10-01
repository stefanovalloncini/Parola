import SwiftUI

/// About fifteen seconds of the take scrolling into a red playhead at 70 % of the width, its markers standing as flags.
struct StageBand: View {
    let take: RecordingSession
    /// Off while the Stage is out of sight, so the band stops drawing; the take's levels keep filling regardless.
    let isOnScreen: Bool
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    nonisolated static let height: CGFloat = 140
    nonisolated static let barWidth: CGFloat = 3
    nonisolated static let gap: CGFloat = 2
    nonisolated static let playhead: CGFloat = 0.7
    nonisolated static let visibleSamples = 480

    private var drawsLive: Bool { isOnScreen && take.state == .recording }

    var body: some View {
        Group {
            if reduceMotion {
                TimelineView(.animation(minimumInterval: 0.25, paused: !drawsLive)) { _ in band }
            } else {
                let _ = drawsLive ? model.takeLevelTick : 0
                band
            }
        }
        .saturation(take.isPaused ? 0 : 1)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.25), value: take.isPaused)
        .mask {
            LinearGradient(
                stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.08)],
                startPoint: .leading,
                endPoint: .trailing
            )
        }
    }

    private var band: some View {
        let history = model.takeLevels
        let count = history.map { min(Self.visibleSamples, $0.sampleCount, $0.recentCapacity) } ?? 0
        let levels = history?.recent(count) ?? []
        let newest = (history?.sampleCount ?? 0) - 1
        let flags = take.markers.compactMap { Self.markerOffset($0, newestSample: newest) }
        return Canvas { context, size in
            Self.draw(levels: levels, flags: flags, in: &context, size: size)
        }
        .accessibilityElement()
        .accessibilityLabel("Input level")
        .accessibilityValue(take.isPaused ? Text("Paused") : Text(verbatim: AppFormat.percent(Double(levels.last ?? 0))))
        .accessibilityAddTraits(.updatesFrequently)
    }

    nonisolated static func playheadX(width: CGFloat) -> CGFloat {
        (width * playhead).rounded()
    }

    /// The left edge of the bar `offset` samples back from the newest one, which sits against the playhead.
    nonisolated static func barX(offset: Int, playheadX: CGFloat) -> CGFloat {
        playheadX - gap - barWidth - CGFloat(offset) * (barWidth + gap)
    }

    /// How many samples back from the newest a marker at `time` into the take sits; nil once it has left the band.
    nonisolated static func markerOffset(_ time: TimeInterval, newestSample: Int) -> Int? {
        let sample = Int((time * TakeLevelHistory.samplesPerSecond).rounded(.down))
        let offset = max(0, newestSample - sample)
        return offset < visibleSamples ? offset : nil
    }

    private static func draw(levels: [Float], flags: [Int], in context: inout GraphicsContext, size: CGSize) {
        let playheadX = playheadX(width: size.width)
        let mid = size.height / 2
        let tallest = size.height - 16
        let flagColor = DS.Color.accent

        for offset in flags {
            let poleX = barX(offset: offset, playheadX: playheadX) + barWidth / 2 - 0.75
            let pole = CGRect(x: poleX, y: 3, width: 1.5, height: size.height - 11)
            context.fill(Path(roundedRect: pole, cornerRadius: 0.75), with: .color(flagColor.opacity(0.5)))
        }

        var bars = Path()
        for (offset, level) in levels.reversed().enumerated() {
            let x = barX(offset: offset, playheadX: playheadX)
            if x + barWidth < 0 { break }
            let half = LevelBars.height(for: level, idle: 3, max: tallest) / 2
            let rect = CGRect(x: x, y: mid - half, width: barWidth, height: half * 2)
            bars.addRoundedRect(in: rect, cornerSize: CGSize(width: 1.5, height: 1.5), style: .continuous)
        }
        let ink = DS.Color.primaryText
        context.fill(
            bars,
            with: .linearGradient(
                Gradient(stops: [
                    .init(color: ink.opacity(0.55), location: 0),
                    .init(color: ink.opacity(0.55), location: 0.5),
                    .init(color: ink.opacity(0.26), location: 1),
                ]),
                startPoint: .zero,
                endPoint: CGPoint(x: 0, y: size.height)
            )
        )

        for offset in flags {
            let poleRight = barX(offset: offset, playheadX: playheadX) + barWidth / 2 + 0.75
            var pennant = Path()
            pennant.move(to: CGPoint(x: poleRight, y: 3))
            pennant.addLine(to: CGPoint(x: poleRight + 8, y: 6.5))
            pennant.addLine(to: CGPoint(x: poleRight, y: 10))
            pennant.closeSubpath()
            context.fill(pennant, with: .color(flagColor))
        }

        let red = DS.Color.recordingFill
        let line = CGRect(x: playheadX - 0.75, y: 8, width: 1.5, height: size.height - 16)
        context.fill(Path(roundedRect: line, cornerRadius: 0.75), with: .color(red))
        context.fill(Path(ellipseIn: CGRect(x: playheadX - 3.5, y: 2, width: 7, height: 7)), with: .color(red))
        context.fill(Path(ellipseIn: CGRect(x: playheadX - 3.5, y: size.height - 9, width: 7, height: 7)), with: .color(red))
    }
}

enum LevelBars {
    /// The same curve the production meter uses, so quiet speech still lifts the bars.
    static func height(for level: Float, idle: CGFloat, max: CGFloat) -> CGFloat {
        let shaped = CGFloat(pow(Double(min(1, Swift.max(0, level))), 0.6))
        return idle + (max - idle) * shaped
    }
}
