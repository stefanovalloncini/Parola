import SwiftUI
import ParolaCore
import AppKit

struct AboutPane: View {
    @ScaledMetric(relativeTo: .largeTitle) private var iconSize: CGFloat = 48

    var body: some View {
        VStack(alignment: .center, spacing: 14) {
            Image(systemName: "waveform")
                .font(.system(size: iconSize, weight: .light))
                .foregroundStyle(.tint)
                .padding(.top, 32)
            Text("Parola").font(DS.Font.title)
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
                .axLeaf("About.Button.OpenRepository")
                Button("Copy version") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(versionLine, forType: .string)
                }
                .axLeaf("About.Button.CopyVersion")
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
        if build.isEmpty {
            return String(localized: "Version \(marketing)")
        }
        return String(localized: "Version \(marketing) (\(build))")
    }
}
