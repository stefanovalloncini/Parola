import SwiftUI
import ParolaCore

struct SegmentTimingPopover: View {
    let segment: TranscriptSegment
    @Environment(AppModel.self) private var model

    private var current: TranscriptSegment? {
        model.transcript?.segments.first { $0.id == segment.id }
    }

    var body: some View {
        @Bindable var model = model
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Timing")
                    .font(DS.Font.bodyStrong)
                Spacer()
                Picker("", selection: $model.subtitleFPS) {
                    ForEach(Self.fpsOptions, id: \.self) { fps in
                        Text(fpsLabel(fps)).tag(fps)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 96)
                .axLeaf("Timing.Picker.Fps")
            }
            Divider()
            timingRow(.start, value: current?.start ?? segment.start) { delta in
                model.nudgeSegmentStart(id: segment.id, frames: delta)
            }
            timingRow(.end, value: current?.end ?? segment.end) { delta in
                model.nudgeSegmentEnd(id: segment.id, frames: delta)
            }
        }
        .padding(DS.Spacing.regular)
        .frame(width: 260)
        .closesOnEscape()
    }

    private enum Bound: String {
        case start = "Start"
        case end = "End"

        var minusLabel: LocalizedStringKey { self == .start ? "Start −1 frame" : "End −1 frame" }
        var plusLabel: LocalizedStringKey { self == .start ? "Start +1 frame" : "End +1 frame" }
    }

    private func timingRow(_ bound: Bound, value: Double, nudge: @escaping (Int) -> Void) -> some View {
        HStack(spacing: 8) {
            Text(bound.rawValue)
                .font(DS.Font.bodyStrong)
                .foregroundStyle(DS.Color.secondaryText)
                .frame(width: 36, alignment: .leading)
            nudgeButton(bound, by: -1, systemName: "minus", help: "−1 frame", label: bound.minusLabel) { nudge(-1) }
                .axLeaf("Timing.Button.Nudge.\(bound.rawValue).minus")
            Text(Self.format(value))
                .font(DS.Font.mono)
                .frame(maxWidth: .infinity)
            nudgeButton(bound, by: 1, systemName: "plus", help: "+1 frame", label: bound.plusLabel) { nudge(1) }
                .axLeaf("Timing.Button.Nudge.\(bound.rawValue).plus")
        }
    }

    private func nudgeButton(
        _ bound: Bound,
        by delta: Int,
        systemName: String,
        help: LocalizedStringKey,
        label: LocalizedStringKey,
        action: @escaping () -> Void
    ) -> some View {
        let enabled = canNudge(bound, by: delta)
        return Button(action: action) {
            Image(systemName: systemName)
                .font(DS.Font.bodyStrong)
                .frame(width: 26, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: DS.Radius.small)
                        .fill(Color.primary.opacity(0.08))
                )
                .contentShape(Rectangle())
                .opacity(enabled ? 1 : DS.Opacity.disabled)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .help(enabled ? help : limitHelp(bound, by: delta))
        .accessibilityLabel(label)
    }

    private func canNudge(_ bound: Bound, by delta: Int) -> Bool {
        guard let segments = model.transcript?.segments, let current else { return false }
        let fps = model.subtitleFPS
        switch bound {
        case .start:
            let target = SegmentTimingNudge.nudgedStart(segments: segments, id: segment.id, frameDelta: delta, fps: fps)
            return target.map { $0 != current.start } ?? false
        case .end:
            let target = SegmentTimingNudge.nudgedEnd(segments: segments, id: segment.id, frameDelta: delta, fps: fps)
            return target.map { $0 != current.end } ?? false
        }
    }

    private func limitHelp(_ bound: Bound, by delta: Int) -> LocalizedStringKey {
        switch (bound, delta < 0) {
        case (.start, true):
            let isFirst = model.transcript?.segments.first?.id == segment.id
            return isFirst ? "Already at the start of the recording" : "Already at the end of the previous segment"
        case (.end, false):
            return "Already at the start of the next segment"
        default:
            return "The segment can't get any shorter"
        }
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
