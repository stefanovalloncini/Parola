import SwiftUI
import ParolaCore

struct ModelPickerView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Menu {
            ForEach(model.availableModels) { entry in
                Button {
                    if entry.isInstalled {
                        model.selectedModel = entry.name
                    } else {
                        model.downloadModel(entry.name)
                        model.selectedModel = entry.name
                    }
                } label: {
                    HStack {
                        if entry.isInstalled {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        } else {
                            Image(systemName: "arrow.down.circle").foregroundStyle(.secondary)
                        }
                        Text(entry.label)
                        Spacer()
                        if let size = entry.approximateSizeBytes {
                            Text(DS.formatBytes(size)).foregroundStyle(.secondary).font(.caption)
                        }
                    }
                }
            }
            Divider()
            Button("Refresh") { model.refreshModelList() }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "cpu")
                Text(currentLabel)
                    .lineLimit(1)
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Active model. Models are downloaded on demand.")
    }

    private var currentLabel: String {
        model.availableModels.first(where: { $0.name == model.selectedModel })?.label ?? model.selectedModel
    }
}
