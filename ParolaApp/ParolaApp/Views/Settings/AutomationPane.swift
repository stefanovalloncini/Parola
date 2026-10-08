import SwiftUI
import AppKit
import ParolaCore

struct AutomationPane: View {
    private enum Copied { case path, snippet }

    @Environment(AppModel.self) private var model
    @State private var copied: Copied?
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
        return SettingsForm {
            Section {
                SettingRow(
                    "MCP automation bridge",
                    description: "Lets parola-mcp drive this app (transcribe, switch model, control recording…). Listens on 127.0.0.1 only."
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
                LabeledContent("Status") {
                    statusRow
                }
            } footer: {
                Text(bridgeBlurb)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                if let path = Self.resolvedBinaryPath {
                    LabeledContent {
                        HStack(spacing: 8) {
                            Button("Reveal in Finder") { reveal(path: path) }
                                .axLeaf("Automation.Button.RevealMcpBinary")
                            Button("Copy Path") { copy(path, as: .path) }
                                .axLeaf("Automation.Button.CopyMcpPath")
                        }
                    } label: {
                        Text(verbatim: path)
                            .font(DS.Font.mono)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                    }
                } else {
                    LabeledContent {
                        EmptyView()
                    } label: {
                        Label("parola-mcp isn't bundled in this build.", systemImage: "exclamationmark.triangle.fill")
                        #if DEBUG
                        Text("Run `swift build --product parola-mcp` in ParolaCore and relaunch.")
                        #else
                        Text("This build doesn't include parola-mcp. Reinstall from the official DMG, or build it from the Parola source.")
                        #endif
                    }
                }
            } header: {
                Text("parola-mcp binary")
            } footer: {
                if copied == .path { copiedNote("Path copied") }
            }

            if let snippet = Self.mcpJSONSnippet {
                Section {
                    LabeledContent {
                        Button("Copy Snippet") { copy(snippet, as: .snippet) }
                            .axLeaf("Automation.Button.CopySnippet")
                    } label: {
                        Text("Drop this into your MCP client's config (Claude Code .mcp.json, Codex, etc.)")
                    }
                    Text(verbatim: snippet)
                        .font(DS.Font.mono)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } header: {
                    Text("MCP client snippet")
                } footer: {
                    if copied == .snippet { copiedNote("Snippet copied") }
                }
            }

            ResetPaneButton(scope: .automation)
        }
    }

    private func copiedNote(_ text: LocalizedStringKey) -> some View {
        Label(text, systemImage: "checkmark.circle.fill")
            .foregroundStyle(.secondary)
            .transition(.opacity)
    }

    private var statusRow: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(model.automationBridgeRunning ? DS.Palette.success : Color.secondary.opacity(0.5))
                .frame(width: 10, height: 10)
            if model.automationBridgeRunning, let port = model.automationBridgePort {
                Text("Listening on 127.0.0.1:\(String(port))")
                    .font(DS.Font.secondary)
            } else if model.automationBridgeRunning {
                Text("Starting…")
                    .font(DS.Font.secondary)
                    .foregroundStyle(DS.Color.secondaryText)
            } else {
                Text("Bridge disabled")
                    .font(DS.Font.secondary)
                    .foregroundStyle(DS.Color.secondaryText)
            }
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

    private func copy(_ text: String, as target: Copied) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        withAnimation { copied = target }
        confirmationTask?.cancel()
        confirmationTask = Task {
            try? await Task.sleep(for: .seconds(2))
            if Task.isCancelled { return }
            withAnimation { copied = nil }
        }
    }
}
