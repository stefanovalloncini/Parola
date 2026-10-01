import SwiftUI

/// The take at the top of the sidebar, "● Recording 12:34", which leads back to the Stage and is washed red while the Stage shows.
struct SidebarRecordingRow: View {
    let isSelected: Bool
    @Environment(AppModel.self) private var model: AppModel?

    var body: some View {
        if let model, let take = model.recording {
            SidebarRecordingRowFace(take: take, isSelected: isSelected) { model.showStage() }
        }
    }
}

/// Ticks each second while the take records; paused, starting or finishing, it holds still.
private struct SidebarRecordingRowFace: View {
    let take: RecordingSession
    let isSelected: Bool
    let open: () -> Void

    nonisolated static let washInset: CGFloat = 6

    var body: some View {
        if take.state == .recording, let origin = take.clockOrigin {
            TimelineView(.periodic(from: origin, by: 1)) { context in
                row(at: context.date)
            }
        } else {
            row(at: Date())
        }
    }

    private func row(at now: Date) -> some View {
        Button(action: open) {
            Label {
                HStack(spacing: DS.Spacing.small) {
                    Text("Recording")
                        .foregroundStyle(DS.Color.primaryText)
                    Spacer(minLength: DS.Spacing.small)
                    Text(verbatim: StageClock.text(seconds: Int(take.elapsed(at: now))))
                        .monospacedDigit()
                        .foregroundStyle(DS.Color.secondaryText)
                }
            } icon: {
                RecDot(color: TakeRemote.lamp(for: take).tint.color)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Self.washInset)
            .padding(.vertical, DS.Spacing.snug)
            .rowChrome(selected: isSelected, hovered: false, selection: .wash(fill: DS.Color.recordingFill.opacity(0.14)))
            .padding(.horizontal, -Self.washInset)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Recording")
        .accessibilityValue(Text(verbatim: TakeRemote.spokenStatus(for: take, at: now)))
        .accessibilityAddTraits(isSelected ? [.isSelected, .updatesFrequently] : .updatesFrequently)
    }
}
