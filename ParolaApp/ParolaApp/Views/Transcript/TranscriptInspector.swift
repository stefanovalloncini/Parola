import SwiftUI

struct TranscriptInspector: View {
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
                    }
                }
                .padding(DS.Spacing.regular)
            }
        }
        .chromeSurface()
    }

    private var modeRow: some View {
        HStack(spacing: DS.Spacing.tight) {
            InspectorModeIcon(systemName: "textformat", label: "Format", isOn: mode == .format) { mode = .format }
                .help("Format")
            InspectorModeIcon(systemName: "info.circle", label: "Info", isOn: mode == .info) { mode = .info }
                .help("Info")
            Spacer()
            InspectorModeIcon(systemName: "rectangle.righthalf.filled", label: "Hide inspector", isOn: false) {
                inspectorVisible = false
            }
            .help("Hide inspector")
        }
    }
}

struct InspectorModeIcon: View {
    let systemName: String
    let label: LocalizedStringKey
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(DS.Font.body)
                .frame(width: 32, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: DS.Radius.small, style: .continuous)
                        .fill(isOn ? DS.Color.accent.opacity(0.15) : Color.clear)
                )
                .foregroundStyle(isOn ? DS.Color.accent : DS.Color.primaryText)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(isOn ? .isSelected : [])
        .axLeaf("Inspector.Button.\(systemName.replacingOccurrences(of: ".", with: ""))")
    }
}

struct InspectorSection<Content: View>: View {
    private let titleText: Text
    private let content: Content

    init(title: LocalizedStringKey, @ViewBuilder content: () -> Content) {
        self.titleText = Text(title)
        self.content = content()
    }

    init(titleVerbatim: String, @ViewBuilder content: () -> Content) {
        self.titleText = Text(titleVerbatim)
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.small) {
            titleText
                .font(DS.Font.caption)
                .foregroundStyle(DS.Color.secondaryText)
                .textCase(.uppercase)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct InspectorDisclosureRow<Content: View>: View {
    let title: LocalizedStringKey
    @Binding var isExpanded: Bool
    let content: Content

    init(title: LocalizedStringKey, isExpanded: Binding<Bool>, @ViewBuilder content: () -> Content) {
        self.title = title
        self._isExpanded = isExpanded
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.small) {
            Button { isExpanded.toggle() } label: {
                HStack {
                    Text(title)
                    Spacer()
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(DS.Font.subheadline)
                        .foregroundStyle(DS.Color.secondaryText)
                }
            }
            .buttonStyle(.plain)
            .axLeaf("Inspector.Button.DisclosureRow")

            if isExpanded {
                content
            }
        }
    }
}
