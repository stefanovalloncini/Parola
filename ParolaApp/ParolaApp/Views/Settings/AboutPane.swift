import SwiftUI
import ParolaCore

struct AboutPane: View {
    var body: some View {
        VStack(alignment: .center, spacing: 14) {
            Image(systemName: "waveform")
                .font(.system(size: 48, weight: .light))
                .foregroundStyle(.tint)
                .padding(.top, 32)
            Text("Parola").font(.system(size: 22, weight: .semibold))
            Text("Version \(Parola.version)")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Text("On-device speech-to-text for macOS, built on WhisperKit.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}
