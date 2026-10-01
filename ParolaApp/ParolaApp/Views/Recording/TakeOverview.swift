import SwiftUI

/// The whole take across the band, squeezed to fit once it runs long; the bars its run has read turn to the accent.
struct TakeOverview: View {
    let progress: Double?
    @Environment(AppModel.self) private var model
    @State private var width: CGFloat = 0

    nonisolated static let barWidth: CGFloat = 2
    nonisolated static let gap: CGFloat = 1
    nonisolated static let rulerGap: CGFloat = 6
    nonisolated static let rulerHeight: CGFloat = 14
    nonisolated static let barsHeight: CGFloat = StageBand.height - rulerGap - rulerHeight

    var body: some View {
        let layout = TakeOverviewLayout(levels: model.takeLevels, width: width, progress: progress)
        Canvas { context, size in
            Self.drawBars(layout, width: size.width, in: &context)
            Self.drawRuler(layout, width: size.width, in: &context)
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        // A Canvas element carries no value; a text stand-in reads the take's length and how far its run has read.
        .accessibilityRepresentation {
            Text(verbatim: AppFormat.elapsed(layout.elapsed))
                .accessibilityLabel("Recording levels")
                .accessibilityValue(Text(verbatim: progress.map { AppFormat.percent($0) } ?? AppFormat.elapsed(layout.elapsed)))
        }
    }

    private static func drawBars(_ layout: TakeOverviewLayout, width: CGFloat, in context: inout GraphicsContext) {
        let height = barsHeight
        let edge = CGFloat(layout.bars.count) * layout.step
        if edge < width {
            let rest = CGRect(x: edge, y: height / 2 - 0.5, width: width - edge, height: 1)
            context.fill(Path(rest), with: .color(DS.Color.primaryText.opacity(0.08)))
        }
        var settled = Path()
        var swept = Path()
        for (index, level) in layout.bars.enumerated() {
            let barHeight = LevelBars.height(for: level, idle: 2, max: height - 4)
            let rect = CGRect(x: CGFloat(index) * layout.step, y: (height - barHeight) / 2, width: barWidth, height: barHeight)
            if index < layout.sweptBars {
                swept.addRoundedRect(in: rect, cornerSize: CGSize(width: 1, height: 1), style: .continuous)
            } else {
                settled.addRoundedRect(in: rect, cornerSize: CGSize(width: 1, height: 1), style: .continuous)
            }
        }
        context.fill(settled, with: .color(DS.Color.secondaryText.opacity(0.55)))
        context.fill(swept, with: .color(DS.Color.accent))
        if layout.sweptBars > 0 {
            let x = CGFloat(layout.sweptBars) * layout.step - gap / 2
            let line = CGRect(x: x - 0.75, y: 2, width: 1.5, height: height - 4)
            context.fill(Path(roundedRect: line, cornerRadius: 0.75), with: .color(DS.Color.accent))
        }
    }

    private static func drawRuler(_ layout: TakeOverviewLayout, width: CGFloat, in context: inout GraphicsContext) {
        guard layout.elapsed > 0 else { return }
        let top = barsHeight + rulerGap
        let current = label(Int(layout.elapsed), in: context)
        let currentX = min(width, layout.x(at: layout.elapsed))
        let currentFrame = labelFrame(width: current.measure(in: CGSize(width: 200, height: 20)).width, at: currentX, limit: width)
        var lastEnd: CGFloat = -.infinity
        var tick = 0.0
        while tick < layout.elapsed {
            let x = layout.x(at: tick)
            let text = label(Int(tick), in: context)
            let frame = labelFrame(width: text.measure(in: CGSize(width: 200, height: 20)).width, at: x, limit: width)
            if frame.minX > lastEnd + 8, frame.maxX < currentFrame.minX - 8 {
                context.draw(text, at: CGPoint(x: frame.minX, y: top), anchor: .topLeading)
                drawTick(at: x, top: top, width: width, in: &context)
                lastEnd = frame.maxX
            }
            tick += layout.tickInterval
        }
        context.draw(current, at: CGPoint(x: currentFrame.minX, y: top), anchor: .topLeading)
        drawTick(at: currentX, top: top, width: width, in: &context)
    }

    private static func label(_ seconds: Int, in context: GraphicsContext) -> GraphicsContext.ResolvedText {
        context.resolve(
            Text(verbatim: StageClock.text(seconds: seconds))
                .font(DS.Font.footnoteDigits)
                .foregroundStyle(DS.Color.secondaryText)
        )
    }

    /// Centred under its moment, except where that would push it past either edge.
    private static func labelFrame(width: CGFloat, at x: CGFloat, limit: CGFloat) -> CGRect {
        let minX = min(max(0, x - width / 2), max(0, limit - width))
        return CGRect(x: minX, y: 0, width: width, height: rulerHeight)
    }

    private static func drawTick(at x: CGFloat, top: CGFloat, width: CGFloat, in context: inout GraphicsContext) {
        let rect = CGRect(x: min(max(0, x - 0.5), width - 1), y: top - rulerGap + 1, width: 1, height: 3)
        context.fill(Path(rect), with: .color(DS.Color.primaryText.opacity(0.18)))
    }
}

/// Where each bar of the overview stands, how many the run has read, and which moments the ruler names.
struct TakeOverviewLayout {
    let bars: [Float]
    let step: CGFloat
    let secondsPerBar: Double
    let elapsed: Double
    let tickInterval: Double
    let sweptBars: Int

    private static let tickChoices: [Double] = [1, 2, 5, 10, 15, 30, 60, 120, 300, 600, 900, 1800, 3600, 7200]

    @MainActor
    init(
        levels: TakeLevelHistory?, width: CGFloat, progress: Double?,
        barWidth: CGFloat = TakeOverview.barWidth, gap: CGFloat = TakeOverview.gap
    ) {
        step = barWidth + gap
        let slots = max(1, Int((width + gap) / step))
        let samples = levels?.overview.count ?? 0
        let perSample = levels?.secondsPerOverviewSample ?? 1 / TakeLevelHistory.samplesPerSecond
        bars = levels?.pooled(into: slots) ?? []
        secondsPerBar = samples > slots ? Double(samples) / Double(slots) * perSample : perSample
        elapsed = Double(samples) * perSample
        if let progress {
            sweptBars = Int((Double(bars.count) * min(1, max(0, progress))).rounded())
        } else {
            sweptBars = 0
        }
        tickInterval = Self.tickInterval(spanning: Double(slots) * secondsPerBar)
    }

    func x(at seconds: Double) -> CGFloat {
        CGFloat(seconds / secondsPerBar) * step
    }

    /// The finest step that names at most six moments across the band.
    private static func tickInterval(spanning seconds: Double) -> Double {
        // A span pooled from tenths of a second lands a hair over a round number; that must not cost a step.
        tickChoices.first { seconds / $0 <= 6 + 1e-9 } ?? 7200
    }
}
