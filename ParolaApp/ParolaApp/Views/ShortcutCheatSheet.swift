import SwiftUI
import ParolaCore

struct ShortcutCatalog {
    struct Entry: Hashable, Identifiable {
        let id = UUID()
        let label: String
        let keys: String
        var requires: ParolaFeature?

        init(label: String, keys: String, requires: ParolaFeature? = nil) {
            self.label = label
            self.keys = keys
            self.requires = requires
        }
    }

    struct Section: Hashable, Identifiable {
        let id = UUID()
        let title: String
        let entries: [Entry]
    }

    static func sections(features: FeatureSet) -> [Section] {
        allSections.compactMap { section in
            let entries = section.entries.filter { entry in
                entry.requires.map(features.isEnabled) ?? true
            }
            return entries.isEmpty ? nil : Section(title: section.title, entries: entries)
        }
    }

    private static let allSections: [Section] = [
        Section(title: "Capture", entries: [
            Entry(label: "Toggle Live Captions",   keys: "⌘ ⇧ L", requires: .liveCaptions),
            Entry(label: "Enter Presenter Mode",   keys: "⌘ ⇧ P", requires: .liveCaptions),
            Entry(label: "Show Scratchpad",        keys: "⌘ ⇧ K", requires: .dictation),
        ]),
        Section(title: "Transcript", entries: [
            Entry(label: "Find",                   keys: "⌘ F"),
            Entry(label: "Export as TXT",          keys: "⌘ E"),
            Entry(label: "Print Transcript",       keys: "⌘ P"),
            Entry(label: "Focus Chat Composer",    keys: "⌘ L", requires: .ai),
            Entry(label: "Toggle Inspector",       keys: "⌘ ⇧ I"),
        ]),
        Section(title: "Playback", entries: [
            Entry(label: "Play / Pause",           keys: "Space"),
            Entry(label: "Skip Back 5 Seconds",    keys: "⌘ ←"),
            Entry(label: "Skip Forward 5 Seconds", keys: "⌘ →"),
        ]),
        Section(title: "Navigation", entries: [
            Entry(label: "Back to the List",       keys: "⌘ ["),
            Entry(label: "Open Settings",          keys: "⌘ ,"),
            Entry(label: "Open File",              keys: "⌘ O"),
            Entry(label: "Auto-Detect Language",   keys: "⌘ ⇧ D"),
        ]),
        Section(title: "Help", entries: [
            Entry(label: "Keyboard Shortcuts",     keys: "⌘ /"),
        ]),
    ]
}

struct ShortcutCheatSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var model

    var body: some View {
        SheetFrame(icon: "command", title: "Keyboard Shortcuts", onClose: { dismiss() }) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    ForEach(ShortcutCatalog.sections(features: model.features)) { section in
                        sectionView(section)
                    }
                }
                .padding(DS.Spacing.medium)
            }
        }
        .sheetSize(width: 420, minHeight: 480, maxHeight: 560)
    }

    private func sectionView(_ section: ShortcutCatalog.Section) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(section.title.uppercased())
                .font(DS.Font.caption)
                .foregroundStyle(DS.Color.secondaryText)
            VStack(alignment: .leading, spacing: 4) {
                ForEach(section.entries) { entry in
                    HStack {
                        Text(entry.label)
                            .font(DS.Font.body)
                        Spacer()
                        Text(entry.keys)
                            .font(DS.Font.mono)
                            .padding(.horizontal, DS.Spacing.small)
                            .padding(.vertical, DS.Spacing.hair)
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
