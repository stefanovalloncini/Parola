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
                    HStack(spacing: 6) {
                        Text("Version \(Self.versionString)")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                        if let channel = Self.channelLabel {
                            Text(channel)
                                .font(.system(size: 10, weight: .semibold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .background(
                                    Capsule().fill(DS.Color.accent.opacity(0.18))
                                )
                                .foregroundStyle(DS.Color.accent)
                        }
                    }
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

    private static var channelLabel: String? {
        #if DEBUG
        return "DEBUG"
        #else
        guard let receiptURL = Bundle.main.appStoreReceiptURL else { return nil }
        let path = receiptURL.path
        if path.contains("sandboxReceipt") { return "TESTFLIGHT" }
        if FileManager.default.fileExists(atPath: path) { return "APP STORE" }
        return nil
        #endif
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
