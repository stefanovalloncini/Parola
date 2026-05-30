import SwiftUI
import ParolaCore

struct AboutSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @ScaledMetric(relativeTo: .largeTitle) private var iconSize: CGFloat = 44

    var body: some View {
        VStack(spacing: 18) {
            HStack(spacing: 14) {
                Image(systemName: "waveform")
                    .font(.system(size: iconSize, weight: .regular))
                    .foregroundStyle(DS.Color.accent)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Parola")
                        .font(DS.Font.title)
                    HStack(spacing: 6) {
                        Text("Version \(Self.versionString)")
                            .font(DS.Font.callout)
                            .foregroundStyle(.secondary)
                        if let channel = Self.channelLabel {
                            Text(channel)
                                .font(DS.Font.caption2Emphasized)
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
                creditRow(title: "Auto-update", value: "Sparkle")
                creditRow(title: "Models on disk", value: modelsOnDiskLabel)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Spacer(minLength: 0)

            HStack {
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .axLeaf("About.Button.Close")
            }
        }
        .padding(20)
        .frame(width: 380, height: 360)
        .axBranch("About")
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

    private var modelsOnDiskLabel: String {
        let installed = model.availableModels.filter { $0.isInstalled }
        let total = installed.reduce(0) { $0 + ($1.approximateSizeBytes ?? 0) }
        if total == 0 { return "—" }
        return "\(installed.count) · \(ByteCountFormatter.string(fromByteCount: Int64(total), countStyle: .file))"
    }

    private func creditRow(title: LocalizedStringKey, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(title)
                .font(DS.Font.subheadlineEmphasized)
                .foregroundStyle(.secondary)
                .frame(width: 90, alignment: .leading)
            Text(verbatim: value)
                .font(DS.Font.callout)
                .foregroundStyle(.primary)
        }
    }
}
