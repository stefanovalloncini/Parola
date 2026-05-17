import SwiftUI
import AppKit
import ParolaCore

struct AutomationPane: View {
    @EnvironmentObject var model: AppModel
    @State private var portText: String? = readBridgePort()
    @State private var copyConfirmation: String?
    @State private var refreshTimer: Timer?

    private static func readBridgePort() -> String? {
        let url = FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("Parola/bridge.port")
        guard let url,
              let raw = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private var mcpBinaryPath: String {
        // Bundled location when shipped inside Parola.app's Contents/MacOS.
        if let bundled = Bundle.main.executableURL?
            .deletingLastPathComponent()
            .appendingPathComponent("parola-mcp").path,
           FileManager.default.isExecutableFile(atPath: bundled) {
            return bundled
        }
        // Dev fallback: the SwiftPM build output in the workspace.
        return "/Users/stefano/Dev/Parola/ParolaCore/.build/debug/parola-mcp"
    }

    private var mcpJSONSnippet: String {
        """
        {
          "mcpServers": {
            "parola": {
              "command": "\(mcpBinaryPath)",
              "args": [],
              "env": {}
            }
          }
        }
        """
    }

    var body: some View {
        ScrollView {
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
                                portText = Self.readBridgePort()
                            }
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
                        Text(mcpBinaryPath)
                            .font(.system(.caption, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(.secondary)
                        HStack(spacing: 8) {
                            Button("Reveal in Finder") { revealMCPBinary() }
                            Button("Copy path") { copy(mcpBinaryPath, label: "Path copied") }
                        }
                    }
                    .padding(16)
                }

                SettingsSection("MCP client snippet") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Drop this into your MCP client's config (Claude Code .mcp.json, Codex, etc.)")
                            .font(DS.Font.caption)
                            .foregroundStyle(.secondary)
                        ScrollView {
                            Text(mcpJSONSnippet)
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
                        Button("Copy snippet") { copy(mcpJSONSnippet, label: "Snippet copied") }
                    }
                    .padding(16)
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
            }
            .padding(20)
        }
        .onAppear {
            portText = Self.readBridgePort()
            refreshTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { _ in
                Task { @MainActor in portText = Self.readBridgePort() }
            }
        }
        .onDisappear {
            refreshTimer?.invalidate()
            refreshTimer = nil
        }
    }

    private var statusRow: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(model.automationBridgeRunning ? Color.green : Color.secondary.opacity(0.5))
                .frame(width: 10, height: 10)
            if model.automationBridgeRunning, let port = portText {
                Text("Listening on 127.0.0.1:\(port)")
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
            return "parola-mcp can now connect over loopback and expose Parola actions to MCP clients. Anyone on this Mac can connect — turn it off if you're sharing the machine."
        }
        #if DEBUG
        return "Debug builds default the bridge on for development. Toggle it off to ship the same workflow as a Release user."
        #else
        return "Release builds keep the bridge off by default so notarised binaries don't open a local listener without consent. Turn it on when you want to drive Parola from Claude Code / Codex / a custom MCP client."
        #endif
    }

    private func revealMCPBinary() {
        let url = URL(fileURLWithPath: mcpBinaryPath)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func copy(_ text: String, label: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        withAnimation { copyConfirmation = label }
        Task {
            try? await Task.sleep(for: .seconds(2))
            withAnimation { copyConfirmation = nil }
        }
    }
}
