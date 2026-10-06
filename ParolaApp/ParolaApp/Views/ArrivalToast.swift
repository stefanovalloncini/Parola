import SwiftUI
import ParolaCore

/// Says what a watched-folder file out of sight is doing; it never takes the window.
struct ArrivalToast: View {
    @Environment(AppModel.self) private var model
    let notice: ArrivalNotice
    var dismissAfter: Duration = DeliveryToast.dismissAfter
    @State private var isOnScreen = false

    private struct Countdown: Equatable {
        let notice: ArrivalNotice
        let shown: Bool
    }

    var body: some View {
        HStack(alignment: .center, spacing: DS.Spacing.regular) {
            if notice.state == .running {
                ProgressView()
                    .controlSize(.small)
            } else {
                Image(systemName: symbol)
                    .font(DS.Font.bodyStrong)
                    .foregroundStyle(tint)
            }
            VStack(alignment: .leading, spacing: 2) {
                // Unbounded, the window's minimum height counts this title wrapped about a character a line, and the page outgrows the window.
                title
                    .font(DS.Font.secondary)
                    .foregroundStyle(DS.Color.primaryText)
                    .lineLimit(2)
                if let reason = notice.reason {
                    // The reason comes from the failure, and a path in it must not be read as markdown.
                    Text(verbatim: reason)
                        .font(DS.Font.caption)
                        .foregroundStyle(DS.Color.secondaryText)
                        .lineLimit(2)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: DS.Spacing.small)
            switch notice.state {
            case .saved:
                Button("Open") {
                    model.openArrivalNotice()
                }
                .buttonStyle(DSPillButtonStyle(kind: .secondary, size: .compact))
                .axLeaf("Arrival.Button.Open")
            case .running:
                Button("Stop") {
                    model.stopBackgroundArrival()
                }
                .buttonStyle(DSPillButtonStyle(kind: .secondary, size: .compact))
                .axLeaf("Arrival.Button.Stop")
            case .paused, .unsaved:
                retryButton
            case .failed:
                retryButton
                Button("Reveal") {
                    model.revealFailedArrival()
                }
                .buttonStyle(DSPillButtonStyle(kind: .secondary, size: .compact))
                .help("Reveal in Finder")
                .axLeaf("Arrival.Button.Reveal")
            }
            Button {
                if notice.state == .running {
                    model.hideRunningArrival()
                } else {
                    model.dismissArrivalNotice()
                }
            } label: {
                Image(systemName: "xmark")
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.secondaryText)
            }
            .buttonStyle(GlyphButtonStyle(side: 20))
            .help("Dismiss")
            .accessibilityLabel("Dismiss")
            .axLeaf("Arrival.Button.Dismiss")
        }
        .padding(.horizontal, DS.Spacing.regular)
        .padding(.vertical, DS.Spacing.small)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.regular, style: .continuous)
                .fill(DS.Color.surfaceElevated)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.regular, style: .continuous)
                .strokeBorder(tint.opacity(0.35), lineWidth: 1)
        )
        .padding(DS.Spacing.regular)
        .background(WindowShownReader { isOnScreen = $0 })
        // Counts down only while its window is on screen, so one raised out of sight waits for the user.
        .task(id: Countdown(notice: notice, shown: isOnScreen)) {
            guard notice.dismissesItself, isOnScreen else { return }
            await model.dismissArrivalNotice(notice, after: dismissAfter)
        }
        .axBranch("ArrivalToast")
    }

    private var retryButton: some View {
        Button("Retry") {
            model.retryArrivalNotice()
        }
        .buttonStyle(DSPillButtonStyle(kind: .primary, size: .compact))
        .axLeaf("Arrival.Button.Retry")
    }

    private var title: Text {
        Text(verbatim: notice.title())
    }

    private var symbol: String {
        switch notice.state {
        case .running: return "waveform"
        case .saved: return "checkmark.circle.fill"
        case .failed, .paused, .unsaved: return "exclamationmark.triangle.fill"
        }
    }

    private var tint: Color {
        switch notice.state {
        case .running: return DS.Color.accent
        case .saved: return DS.Palette.success
        case .failed: return DS.Color.danger
        case .paused, .unsaved: return DS.Palette.warning
        }
    }
}
