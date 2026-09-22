import SwiftUI

struct HelloScene: View {
    let brand: Namespace.ID

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var titleVisible = false

    var body: some View {
        VStack(spacing: DS.Spacing.large) {
            BrandWaveform(side: 240)
                .brandBars(in: brand)
            VStack(spacing: DS.Spacing.small) {
                Text(verbatim: "Parola")
                    .font(DS.Font.wordmark)
                    .tracking(DS.Tracking.wordmark)
                    .foregroundStyle(DS.Color.primaryText)
                Text("Audio, written down.")
                    .font(DS.Font.title)
                    .foregroundStyle(DS.Color.secondaryText)
            }
            .opacity(titleVisible ? 1 : 0)
            .offset(y: titleVisible ? 0 : 8)
        }
        .frame(maxWidth: .infinity)
        .onAppear {
            guard !reduceMotion else {
                titleVisible = true
                return
            }
            withAnimation(.easeOut(duration: 0.35).delay(0.45)) { titleVisible = true }
        }
    }
}
