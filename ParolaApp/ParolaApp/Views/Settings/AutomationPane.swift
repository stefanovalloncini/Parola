import SwiftUI
import AppKit
import ParolaCore

struct AutomationPane: View {
    @Environment(AppModel.self) private var model
    @State private var copyConfirmation: String?
    @State private var confirmationTask: Task<Void, Never>?

    // Probed once per launch; the fallback copy below tells you to relaunch after building parola-mcp.
    private static let resolvedBinaryPath: String? = bundledBinaryPath() ?? developmentBinaryPath()

    private static func bundledBinaryPath() -> String? {
        guard let bundled = Bundle.main.executableURL?
            .deletingLastPathComponent()
            .appendingPathComponent("parola-mcp").path else { return nil }
        return FileManager.default.isExecutableFile(atPath: bundled) ? bundled : nil
    }

    private static func developmentBinaryPath() -> String? {
        #if DEBUG
        let workspace = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("ParolaCore/.build/debug/parola-mcp")
            .path
        return FileManager.default.isExecutableFile(atPath: workspace) ? workspace : nil
        #else
        return nil
        #endif
    }

    private static let mcpJSONSnippet: String? = resolvedBinaryPath.map { path in
        """
        {
          "mcpServers": {
            "parola": {
              "command": "\(path)",
              "args": [],
              "env": {}
            }
          }
        }
        """
    }

    var body: some View {
        @Bindable var model = model
        return ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                SettingsSection {
                    SettingRow(
                        "Enable MCP automation bridge",
                        description: "Lets parola-mcp drive this app (transcribe, switch model, control recording…). Listens on 127.0.0.1 only.",
                        isFirst: true
                    ) {
                        Toggle("", isOn: $model.automationBridgeEnabled)
                            .labelsHidden()
                            .onChange(of: model.automationBridgeEnabled) { _, isOn in
                                if isOn {
                                    model.startAutomationBridge()
                                } else {
                                    model.stopAutomationBridge()
                                }
                            }
                            .axLeaf("Automation.Toggle.BridgeEnabled")
                    }
                }

                SettingsSection("Status") {
                    VStack(alignment: .leading, spacing: 10) {
                        statusRow
                        Text(bridgeBlurb)
                            .font(DS.Font.secondary)
                            .foregroundStyle(DS.Color.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(16)
                }

                SettingsSection("parola-mcp binary") {
                    VStack(alignment: .leading, spacing: 8) {
                        if let path = Self.resolvedBinaryPath {
                            Text(path)
                                .font(.system(.caption, design: .monospaced))
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .foregroundStyle(DS.Color.secondaryText)
                            HStack(spacing: 8) {
                                Button("Reveal in Finder") { reveal(path: path) }
                                    .axLeaf("Automation.Button.RevealMcpBinary")
                                Button("Copy Path") { copy(path, label: String(localized: "Path copied")) }
                                    .axLeaf("Automation.Button.CopyMcpPath")
                            }
                        } else {
                            HStack(spacing: 6) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(DS.Palette.warning)
                                Text("parola-mcp isn't bundled in this build.")
                                    .font(DS.Font.secondary)
                            }
                            #if DEBUG
                            Text("Run `swift build --product parola-mcp` in ParolaCore and relaunch.")
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(DS.Color.secondaryText)
                            #else
                            Text("This build doesn't include parola-mcp. Reinstall from the official DMG, or build it from the Parola source.")
                                .font(DS.Font.secondary)
                                .foregroundStyle(DS.Color.secondaryText)
                            #endif
                        }
                    }
                    .padding(16)
                }

                if let snippet = Self.mcpJSONSnippet {
                    SettingsSection("MCP client snippet") {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Drop this into your MCP client's config (Claude Code .mcp.json, Codex, etc.)")
                                .font(DS.Font.secondary)
                                .foregroundStyle(DS.Color.secondaryText)
                            ScrollView {
                                Text(snippet)
                                    .font(.system(.caption, design: .monospaced))
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(10)
                            }
                            .frame(maxHeight: 160)
                            .background(
                                RoundedRectangle(cornerRadius: DS.Radius.small, style: .continuous)
                                    .fill(Color.primary.opacity(0.05))
                            )
                            Button("Copy Snippet") { copy(snippet, label: String(localized: "Snippet copied")) }
                                .axLeaf("Automation.Button.CopySnippet")
                        }
                        .padding(16)
                    }
                }

                if let confirmation = copyConfirmation {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(DS.Color.successText)
                        Text(confirmation)
                            .font(DS.Font.secondary)
                            .foregroundStyle(DS.Color.secondaryText)
                    }
                    .transition(.opacity)
                }

                ResetPaneButton(scope: .automation)
            }
            .padding(20)
        }
    }

    private var statusRow: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(model.automationBridgeRunning ? DS.Palette.success : Color.secondary.opacity(0.5))
                .frame(width: 10, height: 10)
            if model.automationBridgeRunning, let port = model.automationBridgePort {
                Text("Listening on 127.0.0.1:\(String(port))")
                    .font(DS.Font.subheadline)
            } else if model.automationBridgeRunning {
                Text("Starting…")
                    .font(DS.Font.subheadline)
                    .foregroundStyle(DS.Color.secondaryText)
            } else {
                Text("Bridge disabled")
                    .font(DS.Font.subheadline)
                    .foregroundStyle(DS.Color.secondaryText)
            }
            Spacer()
        }
    }

    private var bridgeBlurb: String {
        if model.automationBridgeRunning {
            return String(localized: "parola-mcp can now connect over loopback and expose Parola actions to MCP clients. Clients authenticate with a token file in ~/Library/Caches/Parola that only your macOS user can read.")
        }
        #if DEBUG
        return String(localized: "Debug builds default the bridge on for development. Toggle it off to ship the same workflow as a Release user.")
        #else
        return String(localized: "Release builds keep the bridge off by default so notarised binaries don't open a local listener without consent. Turn it on when you want to drive Parola from Claude Code / Codex / a custom MCP client.")
        #endif
    }

    private func reveal(path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    private func copy(_ text: String, label: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        withAnimation { copyConfirmation = label }
        confirmationTask?.cancel()
        confirmationTask = Task {
            try? await Task.sleep(for: .seconds(2))
            if Task.isCancelled { return }
            withAnimation { copyConfirmation = nil }
        }
    }
}
