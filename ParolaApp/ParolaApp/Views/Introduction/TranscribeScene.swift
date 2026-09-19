import SwiftUI

struct TranscribeScene: View {
    var body: some View {
        Text("It listens and writes.")
            .font(DS.Font.hero)
            .foregroundStyle(DS.Color.primaryText)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
