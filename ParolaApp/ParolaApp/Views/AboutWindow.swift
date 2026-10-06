import SwiftUI
import AppKit
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

/// Icon, version, channel badge, and credits: the About window's body.
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
                            .font(DS.Font.secondary)
                            .foregroundStyle(DS.Color.secondaryText)
                        if let channel = AboutInfo.channelLabel {
                            Text(channel)
                                .font(DS.Font.caption)
                                .padding(.horizontal, DS.Spacing.snug)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(DS.Color.accentWash))
                                .foregroundStyle(DS.Color.accentInk)
                        }
                    }
                }
                Spacer()
            }

            Divider()

            AboutCredits(rows: credits)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task { model.refreshModelList() }
    }

    private var credits: [AboutCredit] {
        var rows = [
            AboutCredit(title: "Transcription", value: "WhisperKit · FluidAudio Parakeet · Apple Speech"),
            AboutCredit(title: "Local LLM", value: "Apple Foundation Models"),
            AboutCredit(title: "Auto-update", value: "Sparkle"),
        ]
        if let modelsOnDiskLabel {
            rows.append(AboutCredit(title: "Models on disk", value: modelsOnDiskLabel))
        }
        return rows
    }

    private var modelsOnDiskLabel: String? {
        Self.modelsLine(model.modelsOnDiskSummary)
    }

    static func modelsLine(_ summary: ModelsDiskSummary) -> String? {
        summary.bytes > 0 ? summary.usageText : nil
    }
}

struct AboutCredit: Identifiable {
    let title: LocalizedStringKey
    let value: String
    var id: String { value }
}

struct AboutCredits: View {
    let rows: [AboutCredit]

    var body: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 8) {
            ForEach(rows) { row in
                GridRow {
                    Text(row.title)
                        .font(DS.Font.bodyStrong)
                        .foregroundStyle(DS.Color.secondaryText)
                        .fixedSize()
                    Text(verbatim: row.value)
                        .font(DS.Font.body)
                        .foregroundStyle(.primary)
                }
            }
        }
    }
}

enum AboutWindowScene {
    static let id = "about"
}

struct AboutWindow: View {
    @State private var copiedVersion = false

    var body: some View {
        VStack(spacing: 16) {
            AboutInfoView()
            HStack(spacing: 10) {
                Button("Open Repository") {
                    NSWorkspace.shared.open(SupportLinks.repository)
                }
                .axLeaf("Button.OpenRepository")
                Button(copiedVersion ? "Copied" : "Copy Version") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString("Parola \(AboutInfo.versionString)", forType: .string)
                    copiedVersion = true
                    Task {
                        try? await Task.sleep(for: .seconds(1.5))
                        copiedVersion = false
                    }
                }
                .axLeaf("Button.CopyVersion")
            }
            .controlSize(.small)
            if ManagedConfiguration.shared.isActive {
                Text("Some features are managed by your deployment.")
                    .font(DS.Font.secondary)
                    .foregroundStyle(DS.Color.secondaryText)
                    .axLeaf("Text.ManagedNote")
            }
        }
        .padding(DS.Spacing.large)
        .frame(width: 380)
        .axBranch("About")
    }
}
