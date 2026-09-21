import SwiftUI

/// Shown once, the first time a service outside this Mac is saved or picked.
struct RemoteAIAcknowledgementSheet: View {
    let serviceName: String
    let onAccept: () -> Void
    let onCancel: () -> Void

    var body: some View {
        SheetFrame(
            icon: "arrow.up.forward.app",
            title: "Transcripts leave this Mac",
            onClose: onCancel
        ) {
            VStack(alignment: .leading, spacing: 12) {
                Text(explanation)
                    .font(DS.Font.body)
                    .foregroundStyle(DS.Color.primaryText)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Apple Intelligence stays on this Mac. You can switch back to it at any time.")
                    .font(DS.Font.secondary)
                    .foregroundStyle(DS.Color.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(DS.Spacing.regular)
        } footer: {
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .buttonStyle(DSPillButtonStyle(kind: .secondary, size: .compact))
                    .keyboardShortcut(.cancelAction)
                    .axLeaf("AIServices.Button.CancelAcknowledge")
                Button("I understand", action: onAccept)
                    .buttonStyle(DSPillButtonStyle(kind: .primary, size: .compact))
                    .keyboardShortcut(.defaultAction)
                    .axLeaf("AIServices.Button.Acknowledge")
            }
        }
        .sheetSize(width: 460, minHeight: 200, maxHeight: 300)
        .hidesCloseButton()
    }

    private var explanation: String {
        guard !serviceName.isEmpty else {
            return String(localized: "The text of the transcript is sent to the service you picked, and is handled under that provider's terms.")
        }
        return String(localized: "The text of the transcript is sent to \(serviceName), and is handled under that provider's terms.")
    }
}
