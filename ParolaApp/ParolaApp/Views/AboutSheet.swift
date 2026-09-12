import SwiftUI
import ParolaCore

/// Version and channel strings shared by every About surface so they can't drift apart.
enum AboutInfo {
    static var versionString: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }

    static var channelLabel: String? {
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
}

/// Icon, version, channel badge, and credits — the single About body shared by the menu-bar About
/// sheet and the Settings About pane, so the two never present conflicting information.
struct AboutInfoView: View {
    @Environment(AppModel.self) private var model
    @ScaledMetric(relativeTo: .largeTitle) private var iconSize: CGFloat = 44

    var body: some View {
        VStack(spacing: 18) {
            HStack(spacing: 14) {
                Image(systemName: "waveform")
                    .font(.system(size: iconSize, weight: .regular))
                    .foregroundStyle(DS.Color.accent)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Parola")
                        .font(DS.Font.title)
                    HStack(spacing: 6) {
                        Text("Version \(AboutInfo.versionString)")
                            .font(DS.Font.callout)
                            .foregroundStyle(DS.Color.secondaryText)
                        if let channel = AboutInfo.channelLabel {
                            Text(channel)
                                .font(DS.Font.caption2Emphasized)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(DS.Color.accentWash))
                                .foregroundStyle(DS.Color.accentText)
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
        }
        .task { model.refreshModelList() }
    }

    private var modelsOnDiskLabel: String {
        let summary = model.modelsOnDiskSummary
        if summary.bytes == 0 { return "—" }
        return "\(summary.count) · \(AppFormat.byteSize(summary.bytes))"
    }

    private func creditRow(title: LocalizedStringKey, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(title)
                .font(DS.Font.subheadlineEmphasized)
                .foregroundStyle(DS.Color.secondaryText)
                .frame(width: 90, alignment: .leading)
            Text(verbatim: value)
                .font(DS.Font.callout)
                .foregroundStyle(.primary)
        }
    }
}

struct AboutSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        SheetFrame(icon: "waveform", title: "About Parola", onClose: { dismiss() }) {
            AboutInfoView()
                .padding(20)
        }
        .sheetSize(width: 380, minHeight: 340, maxHeight: 420)
        .closeLeaf("About.Button.Close")
        .axBranch("About")
    }
}
