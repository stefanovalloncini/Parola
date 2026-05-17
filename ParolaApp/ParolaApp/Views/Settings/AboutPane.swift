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
            Text(versionLine)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("On-device speech-to-text for macOS, built on WhisperKit.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            Divider().padding(.vertical, 8)

            VStack(spacing: 4) {
                Text("Built on").font(.caption.weight(.semibold))
                Text("WhisperKit · FluidAudio · Sparkle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 10) {
                Button("Open repository") {
                    if let url = URL(string: "https://github.com/stefanovalloncini/Parola") {
                        NSWorkspace.shared.open(url)
                    }
                }
                Button("Copy version") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(versionLine, forType: .string)
                }
            }
            .controlSize(.small)

            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var versionLine: String {
        let info = Bundle.main.infoDictionary
        let marketing = (info?["CFBundleShortVersionString"] as? String) ?? Parola.version
        let build = (info?["CFBundleVersion"] as? String) ?? ""
        return build.isEmpty ? "Version \(marketing)" : "Version \(marketing) (\(build))"
    }
}
