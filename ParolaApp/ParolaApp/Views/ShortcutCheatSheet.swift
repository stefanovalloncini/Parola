import SwiftUI

struct ShortcutCatalog {
    struct Entry: Hashable, Identifiable {
        let id = UUID()
        let label: String
        let keys: String
    }

    struct Section: Hashable, Identifiable {
        let id = UUID()
        let title: String
        let entries: [Entry]
    }

    static let sections: [Section] = [
        Section(title: "Capture", entries: [
            Entry(label: "Toggle Live Captions",   keys: "⌘ ⇧ L"),
            Entry(label: "Enter Presenter Mode",   keys: "⌘ ⇧ P"),
            Entry(label: "Show Scratchpad",        keys: "⌘ ⇧ K"),
        ]),
        Section(title: "Transcript", entries: [
            Entry(label: "Find",                   keys: "⌘ F"),
            Entry(label: "Export as TXT",          keys: "⌘ E"),
            Entry(label: "Print Transcript",       keys: "⌘ P"),
            Entry(label: "Focus Chat Composer",    keys: "⌘ L"),
        ]),
        Section(title: "Navigation", entries: [
            Entry(label: "Open Settings",          keys: "⌘ ,"),
            Entry(label: "Open File",              keys: "⌘ O"),
            Entry(label: "Auto-detect Language",   keys: "⌘ ⇧ D"),
        ]),
        Section(title: "Help", entries: [
            Entry(label: "Keyboard Shortcuts",     keys: "⌘ /"),
        ]),
    ]
}

struct ShortcutCheatSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Keyboard Shortcuts")
                    .font(.title3.weight(.semibold))
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 12)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    ForEach(ShortcutCatalog.sections) { section in
                        sectionView(section)
                    }
                }
                .padding(20)
            }
        }
        .frame(width: 420, height: 480)
    }

    private func sectionView(_ section: ShortcutCatalog.Section) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(section.title.uppercased())
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                ForEach(section.entries) { entry in
                    HStack {
                        Text(entry.label)
                            .font(.body)
                        Spacer()
                        Text(entry.keys)
                            .font(.system(.body, design: .monospaced))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                            .background(
                                RoundedRectangle(cornerRadius: 5)
                                    .fill(Color.primary.opacity(0.08))
                            )
                    }
                }
            }
        }
    }
}
