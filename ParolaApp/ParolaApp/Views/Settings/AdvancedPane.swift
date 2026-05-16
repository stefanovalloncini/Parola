import SwiftUI
import ParolaCore

struct AdvancedPane: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsSection("Model storage") {
                VStack(alignment: .leading, spacing: 8) {
                    Text(model.cacheDirectoryDisplayPath)
                        .font(.system(.caption, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.head)
                        .foregroundStyle(.secondary)
                    Button("Reveal in Finder") { model.revealCacheDirectory() }
                }
                .padding(16)
            }
        }
    }
}
