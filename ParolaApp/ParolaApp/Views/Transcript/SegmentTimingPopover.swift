import SwiftUI
import ParolaCore

struct SegmentTimingPopover: View {
    let segment: TranscriptSegment
    @Environment(AppModel.self) private var model

    private var current: TranscriptSegment? {
        model.transcript?.segments.first { $0.id == segment.id }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Timing")
                    .font(DS.Font.bodyStrong)
                Spacer()
                fpsStepper
            }
            Divider()
            timingRow(label: "Start", value: current?.start ?? segment.start) { delta in
                model.nudgeSegmentStart(id: segment.id, frames: delta)
            }
            timingRow(label: "End", value: current?.end ?? segment.end) { delta in
                model.nudgeSegmentEnd(id: segment.id, frames: delta)
            }
        }
        .padding(DS.Spacing.regular)
        .frame(width: 260)
    }

    private func timingRow(label: String, value: Double, nudge: @escaping (Int) -> Void) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(DS.Font.bodyStrong)
                .foregroundStyle(DS.Color.secondaryText)
                .frame(width: 36, alignment: .leading)
            nudgeButton(systemName: "minus", help: "−1 frame") { nudge(-1) }
            Text(Self.format(value))
                .font(DS.Font.mono)
                .frame(maxWidth: .infinity)
            nudgeButton(systemName: "plus", help: "+1 frame") { nudge(1) }
        }
    }

    private func nudgeButton(systemName: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(DS.Font.bodyStrong)
                .frame(width: 26, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: DS.Radius.small)
                        .fill(Color.primary.opacity(0.08))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .axLeaf("Timing.Button.Nudge.\(systemName)")
    }

    // A menu picker here loses mouse picks: the transient popover closes on the click in the menu's own window.
    private var fpsStepper: some View {
        Stepper(
            onIncrement: fpsSetter(Self.fps(above: model.subtitleFPS)),
            onDecrement: fpsSetter(Self.fps(below: model.subtitleFPS))
        ) {
            Text(fpsLabel(model.subtitleFPS))
                .font(DS.Font.mono)
                .foregroundStyle(DS.Color.secondaryText)
        }
        .help("Frame rate")
        .accessibilityLabel("Frame rate")
        .accessibilityValue(fpsLabel(model.subtitleFPS))
        .axLeaf("Timing.Stepper.Fps")
    }

    private func fpsSetter(_ fps: Double?) -> (() -> Void)? {
        guard let fps else { return nil }
        return { model.subtitleFPS = fps }
    }

    private static let fpsOptions: [Double] = [23.976, 24, 25, 29.97, 30, 50, 59.94, 60]

    static func fps(above current: Double) -> Double? {
        fpsOptions.first { $0 > current + 0.001 }
    }

    static func fps(below current: Double) -> Double? {
        fpsOptions.last { $0 < current - 0.001 }
    }

    private func fpsLabel(_ fps: Double) -> String {
        if abs(fps.rounded() - fps) < 0.01 { return "\(Int(fps.rounded())) fps" }
        return String(format: "%.3f fps", fps)
    }

    private static func format(_ seconds: Double) -> String {
        let hours = Int(seconds) / 3600
        let minutes = (Int(seconds) % 3600) / 60
        let secs = seconds.truncatingRemainder(dividingBy: 60)
        if hours > 0 {
            return String(format: "%02d:%02d:%06.3f", hours, minutes, secs)
        }
        return String(format: "%02d:%06.3f", minutes, secs)
    }
}
