import SwiftUI

struct TranscribeScene: View {
    let demo: DemoPlayback
    let brand: Namespace.ID

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.regular) {
            Text("It listens and writes.")
                .font(DS.Font.hero)
                .foregroundStyle(DS.Color.primaryText)
                .sceneEntrance(order: 0)
            Text("Every word stays on this Mac.")
                .font(DS.Font.title)
                .foregroundStyle(DS.Color.secondaryText)
                .sceneEntrance(order: 1)
            DemoTranscriptCard(demo: demo, brand: brand)
                .padding(.top, DS.Spacing.small)
                .sceneEntrance(order: 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
