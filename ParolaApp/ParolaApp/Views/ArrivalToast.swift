import SwiftUI
import ParolaCore

/// Says a watched-folder file was transcribed out of sight; it never takes the window and goes away on its own.
struct ArrivalToast: View {
    @Environment(AppModel.self) private var model
    let notice: ArrivalNotice

    var body: some View {
        HStack(alignment: .center, spacing: DS.Spacing.regular) {
            Image(systemName: symbol)
                .font(DS.Font.bodyStrong)
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 2) {
                title
                    .font(DS.Font.secondary)
                    .foregroundStyle(DS.Color.primaryText)
                if case .failed(let reason) = notice.state {
                    // The reason comes from the failure, and a path in it must not be read as markdown.
                    Text(verbatim: reason)
                        .font(DS.Font.caption)
                        .foregroundStyle(DS.Color.secondaryText)
                        .lineLimit(2)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: DS.Spacing.small)
            if case .saved = notice.state {
                Button("Open") {
                    model.openArrivalNotice()
                }
                .buttonStyle(DSPillButtonStyle(kind: .secondary, size: .compact))
                .axLeaf("Arrival.Button.Open")
            }
            Button {
                model.dismissArrivalNotice()
            } label: {
                Image(systemName: "xmark")
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.secondaryText)
            }
            .buttonStyle(GlyphButtonStyle(side: 20))
            .help("Dismiss")
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
        .task(id: notice) {
            try? await Task.sleep(for: DeliveryToast.dismissAfter)
            guard !Task.isCancelled, model.arrivalNotice == notice else { return }
            model.dismissArrivalNotice()
        }
        .axBranch("ArrivalToast")
    }

    private var title: Text {
        switch notice.state {
        case .saved:
            return Text("Transcribed \(notice.name) from a watched folder")
        case .failed:
            return Text("Couldn't transcribe \(notice.name)")
        }
    }

    private var symbol: String {
        switch notice.state {
        case .saved: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }

    private var tint: Color {
        switch notice.state {
        case .saved: return DS.Palette.success
        case .failed: return DS.Color.danger
        }
    }
}
