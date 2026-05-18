import SwiftUI

struct AboutSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 18) {
            HStack(spacing: 14) {
                Image(systemName: "waveform")
                    .font(.system(size: 44, weight: .regular))
                    .foregroundStyle(DS.Color.accent)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Parola")
                        .font(.system(size: 22, weight: .semibold))
                    Text("Version \(Self.versionString)")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                creditRow(title: "Transcription", value: "WhisperKit · FluidAudio Parakeet · Apple Speech")
                creditRow(title: "Local LLM", value: "Apple Foundation Models")
                creditRow(title: "Cloud LLM", value: "OpenAI · Anthropic · Groq · Cerebras · Ollama")
                creditRow(title: "Auto-update", value: "Sparkle")
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Spacer(minLength: 0)

            HStack {
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 380, height: 320)
    }

    private static var versionString: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }

    private func creditRow(title: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 90, alignment: .leading)
            Text(value)
                .font(.system(size: 12))
                .foregroundStyle(.primary)
        }
    }
}
