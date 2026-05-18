import SwiftUI

struct TranscriptInspector: View {
    @EnvironmentObject var model: AppModel
    @Binding var mode: InspectorMode
    @Binding var inspectorVisible: Bool

    var body: some View {
        VStack(spacing: 0) {
            modeRow
                .padding(.horizontal, DS.Spacing.regular)
                .padding(.vertical, DS.Spacing.small)
            Divider()

            ScrollView {
                Group {
                    switch mode {
                    case .format: FormatInspector()
                    case .info: InfoInspector()
                    case .actions: ActionsInspector()
                    }
                }
                .padding(DS.Spacing.regular)
            }
        }
        .background(DS.Color.surface)
    }

    private var modeRow: some View {
        HStack(spacing: DS.Spacing.tight) {
            InspectorModeIcon(systemName: "textformat", isOn: mode == .format) { mode = .format }
                .help("Format")
            InspectorModeIcon(systemName: "info.circle", isOn: mode == .info) { mode = .info }
                .help("Info")
            InspectorModeIcon(systemName: "wand.and.stars", isOn: mode == .actions) { mode = .actions }
                .help("Actions")
            Spacer()
            InspectorModeIcon(systemName: "rectangle.righthalf.filled", isOn: false) {
                inspectorVisible = false
            }
            .help("Hide inspector")
        }
    }
}

struct InspectorModeIcon: View {
    let systemName: String
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 14, weight: .regular))
                .frame(width: 32, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(isOn ? DS.Color.accent.opacity(0.15) : Color.clear)
                )
                .foregroundStyle(isOn ? DS.Color.accent : DS.Color.primaryText)
        }
        .buttonStyle(.plain)
    }
}

struct InspectorGroup<Content: View>: View {
    let title: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.small) {
            Text(title)
                .font(DS.Font.caption)
                .foregroundStyle(DS.Color.secondaryText)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct InspectorDisclosureRow<Content: View>: View {
    let title: String
    @Binding var isExpanded: Bool
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.small) {
            Button { isExpanded.toggle() } label: {
                HStack {
                    Text(title)
                    Spacer()
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 11, weight: .regular))
                        .foregroundStyle(DS.Color.secondaryText)
                }
            }
            .buttonStyle(.plain)

            if isExpanded {
                content()
            }
        }
    }
}
