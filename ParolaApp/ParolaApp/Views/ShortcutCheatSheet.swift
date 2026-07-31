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
            Entry(label: "Toggle Inspector",       keys: "⌘ ⇧ I"),
        ]),
        Section(title: "Playback", entries: [
            Entry(label: "Play / Pause",           keys: "Space"),
            Entry(label: "Skip Back 5 Seconds",    keys: "⌘ ←"),
            Entry(label: "Skip Forward 5 Seconds", keys: "⌘ →"),
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
        SheetFrame(icon: "command", title: "Keyboard Shortcuts", onClose: { dismiss() }) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    ForEach(ShortcutCatalog.sections) { section in
                        sectionView(section)
                    }
                }
                .padding(20)
            }
        }
        .sheetSize(width: 420, minHeight: 480, maxHeight: 560)
    }

    private func sectionView(_ section: ShortcutCatalog.Section) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(section.title.uppercased())
                .font(DS.Font.captionEmphasized)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                ForEach(section.entries) { entry in
                    HStack {
                        Text(entry.label)
                            .font(DS.Font.body)
                        Spacer()
                        Text(entry.keys)
                            .font(DS.Font.bodyMono)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                            .background(
                                RoundedRectangle(cornerRadius: DS.Radius.small)
                                    .fill(DS.Palette.subtleFill)
                            )
                    }
                }
            }
        }
    }
}
