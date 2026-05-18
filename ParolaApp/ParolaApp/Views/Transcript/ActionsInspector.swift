import SwiftUI

struct ActionsInspector: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.large) {
            if model.transcript != nil {
                ChaptersSection()
                ActionItemsSection()
            } else {
                Text("Load a transcript to run actions.")
                    .font(DS.Font.body)
                    .foregroundStyle(DS.Color.secondaryText)
            }
        }
    }
}
