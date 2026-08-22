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
        Label {
            Text(message)
                .fixedSize(horizontal: false, vertical: true)
                .multilineTextAlignment(.leading)
        } icon: {
            Image(systemName: kind.symbol)
        }
        .font(DS.Font.caption)
        .foregroundStyle(kind == .failure ? DS.Color.danger : DS.Color.secondaryText)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
