import SwiftUI

/// The take at the top of the sidebar, "● Recording 12:34", which leads back to its Stage, failed or transcribing too, and is washed red while the Stage shows.
struct SidebarRecordingRow: View {
    let isSelected: Bool
    @Environment(AppModel.self) private var model: AppModel?

    /// What VoiceOver reads after the row's "Recording": just the time while it records, what it is doing otherwise.
    nonisolated static func spokenValue(
        for take: RecordingSession, at now: Date, bundle: Bundle = .main, locale: Locale = AppFormat.locale
    ) -> String {
        switch take.state {
        case .recording: AppFormat.spokenDuration(seconds: Int(take.elapsed(at: now)), locale: locale)
        case .transcribing: String(localized: "Transcribing…", bundle: bundle)
        case .failed: String(localized: "Failed", bundle: bundle)
        default: TakeRemote.spokenStatus(for: take, at: now, bundle: bundle, locale: locale)
        }
    }

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
                    status(at: now)
                }
            } icon: {
                icon
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Self.washInset)
            .padding(.vertical, DS.Spacing.snug)
            .rowChrome(selected: isSelected, hovered: false, selection: .wash(fill: DS.Color.recordingFill.opacity(0.14)))
            .padding(.horizontal, -Self.washInset)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Recording")
        .accessibilityValue(Text(verbatim: SidebarRecordingRow.spokenValue(for: take, at: now)))
        .accessibilityAddTraits(isSelected ? [.isSelected, .updatesFrequently] : .updatesFrequently)
    }

    /// The time while the take runs; once it stops, what became of it.
    @ViewBuilder
    private func status(at now: Date) -> some View {
        switch take.state {
        case .transcribing:
            Text("Transcribing…")
                .foregroundStyle(DS.Color.secondaryText)
        case .failed:
            Text("Failed")
                .foregroundStyle(DS.Color.warningText)
        default:
            Text(verbatim: TakeRemote.clock(for: take, now: now))
                .monospacedDigit()
                .foregroundStyle(DS.Color.secondaryText)
        }
    }

    @ViewBuilder
    private var icon: some View {
        if case .failed = take.state {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(DS.Palette.warning)
        } else {
            TakeLight(take: take)
        }
    }
}
