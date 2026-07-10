import SwiftUI
import AppKit
import ParolaCore

struct AutomationPane: View {
    @Environment(AppModel.self) private var model
    @State private var copyConfirmation: String?
    @State private var confirmationTask: Task<Void, Never>?

    private var bundledBinaryPath: String? {
        guard let bundled = Bundle.main.executableURL?
            .deletingLastPathComponent()
            .appendingPathComponent("parola-mcp").path else { return nil }
        return FileManager.default.isExecutableFile(atPath: bundled) ? bundled : nil
    }

    private var developmentBinaryPath: String? {
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

    private var resolvedBinaryPath: String? {
        bundledBinaryPath ?? developmentBinaryPath
    }

    private var mcpJSONSnippet: String? {
        guard let path = resolvedBinaryPath else { return nil }
        return """
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
                            .font(DS.Font.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(16)
                }

                SettingsSection("parola-mcp binary") {
                    VStack(alignment: .leading, spacing: 8) {
                        if let path = resolvedBinaryPath {
                            Text(path)
                                .font(.system(.caption, design: .monospaced))
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .foregroundStyle(.secondary)
                            HStack(spacing: 8) {
                                Button("Reveal in Finder") { reveal(path: path) }
                                    .axLeaf("Automation.Button.RevealMcpBinary")
                                Button("Copy path") { copy(path, label: String(localized: "Path copied")) }
                                    .axLeaf("Automation.Button.CopyMcpPath")
                            }
                        } else {
                            HStack(spacing: 6) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(DS.Palette.warning)
                                Text("parola-mcp isn't bundled in this build.")
                                    .font(DS.Font.caption)
                            }
                            #if DEBUG
                            Text("Run `swift build --product parola-mcp` in ParolaCore and relaunch.")
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                            #else
                            Text("Build parola-mcp from the Parola source, then point your MCP client at the binary.")
                                .font(DS.Font.caption)
                                .foregroundStyle(.secondary)
                            #endif
                        }
                    }
                    .padding(16)
                }

                if let snippet = mcpJSONSnippet {
                    SettingsSection("MCP client snippet") {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Drop this into your MCP client's config (Claude Code .mcp.json, Codex, etc.)")
                                .font(DS.Font.caption)
                                .foregroundStyle(.secondary)
                            ScrollView {
                                Text(snippet)
                                    .font(.system(.caption, design: .monospaced))
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(10)
                            }
                            .frame(maxHeight: 160)
                            .background(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(Color.primary.opacity(0.05))
                            )
                            Button("Copy snippet") { copy(snippet, label: String(localized: "Snippet copied")) }
                                .axLeaf("Automation.Button.CopySnippet")
                        }
                        .padding(16)
                    }
                }

                if let confirmation = copyConfirmation {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Text(confirmation)
                            .font(DS.Font.caption)
                            .foregroundStyle(.secondary)
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
                .fill(model.automationBridgeRunning ? Color.green : Color.secondary.opacity(0.5))
                .frame(width: 10, height: 10)
            if model.automationBridgeRunning, let port = model.automationBridgePort {
                Text("Listening on 127.0.0.1:\(String(port))")
                    .font(.subheadline)
            } else if model.automationBridgeRunning {
                Text("Starting…")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                Text("Bridge disabled")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
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
