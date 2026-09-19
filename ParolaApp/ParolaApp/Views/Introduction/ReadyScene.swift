import SwiftUI

struct ReadyScene: View {
    var body: some View {
        Text("You're ready.")
            .font(DS.Font.hero)
            .foregroundStyle(DS.Color.primaryText)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
