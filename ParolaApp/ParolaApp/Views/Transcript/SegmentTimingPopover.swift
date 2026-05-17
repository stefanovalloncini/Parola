import SwiftUI
import ParolaCore

struct SegmentTimingPopover: View {
    let segment: TranscriptSegment
    @EnvironmentObject var model: AppModel

    private var current: TranscriptSegment? {
        model.transcript?.segments.first { $0.id == segment.id }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Timing")
                    .font(.system(size: 12.5, weight: .semibold))
                Spacer()
                Picker("", selection: $model.subtitleFPS) {
                    ForEach(Self.fpsOptions, id: \.self) { fps in
                        Text(fpsLabel(fps)).tag(fps)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 96)
            }
            Divider()
            timingRow(label: "Start", value: current?.start ?? segment.start) { delta in
                model.nudgeSegmentStart(id: segment.id, frames: delta)
            }
            timingRow(label: "End", value: current?.end ?? segment.end) { delta in
                model.nudgeSegmentEnd(id: segment.id, frames: delta)
            }
        }
        .padding(14)
        .frame(width: 260)
    }

    private func timingRow(label: String, value: Double, nudge: @escaping (Int) -> Void) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(DS.Color.secondaryText)
                .frame(width: 36, alignment: .leading)
            nudgeButton(systemName: "minus", help: "−1 frame") { nudge(-1) }
            Text(Self.format(value))
                .font(.system(size: 12, design: .monospaced).monospacedDigit())
                .frame(maxWidth: .infinity)
            nudgeButton(systemName: "plus", help: "+1 frame") { nudge(1) }
        }
    }

    private func nudgeButton(systemName: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 26, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.primary.opacity(0.08))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private static let fpsOptions: [Double] = [23.976, 24, 25, 29.97, 30, 50, 59.94, 60]

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
