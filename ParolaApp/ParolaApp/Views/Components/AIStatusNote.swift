import SwiftUI

struct AIStatusNote: View {
    enum Kind {
        case unavailable
        case failure

        var symbol: String {
            switch self {
            case .unavailable: "sparkles"
            case .failure: "exclamationmark.triangle"
            }
        }
    }

    let message: String
    var kind: Kind = .unavailable

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.small) {
            Label {
                Text(message)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)
            } icon: {
                Image(systemName: kind.symbol)
            }
            .font(DS.Font.secondary)
            .foregroundStyle(kind == .failure ? DS.Color.dangerText : DS.Color.secondaryText)
            if kind == .unavailable {
                OpenAISettingsButton(leaf: "AIStatusNote.Button.OpenAISettings")
                    .buttonStyle(DSPillButtonStyle(kind: .secondary, size: .compact))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The way out of an AI-unavailable state: Settings ▸ AI Services, where a cloud provider can take the task.
struct OpenAISettingsButton: View {
    @Environment(AppModel.self) private var model
    let leaf: String

    var body: some View {
        Button("Open AI Settings…") { model.openSettings(route: .aiServices) }
            .axLeaf(leaf)
    }
}
