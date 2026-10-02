import SwiftUI
import ParolaCore

struct ShortcutCatalog {
    struct Entry: Hashable, Identifiable {
        let id = UUID()
        let label: String
        let keys: String
        /// Shown when any of these is on; none means always.
        var requires: [ParolaFeature]

        init(label: String, keys: String, requires: ParolaFeature...) {
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

    static func sections(features: FeatureSet, bundle: Bundle = .main) -> [Section] {
        allSections(bundle: bundle).compactMap { section in
            let entries = section.entries.filter { entry in
                entry.requires.isEmpty || entry.requires.contains(where: features.isEnabled)
            }
            return entries.isEmpty ? nil : Section(title: section.title, entries: entries)
        }
    }

    private static func allSections(bundle: Bundle) -> [Section] {
        func text(_ key: String.LocalizationValue) -> String { String(localized: key, bundle: bundle) }
        let space = text("Space")
        return [
            Section(title: text("Capture"), entries: [
                Entry(label: text("New Recording"),              keys: "⌘ N", requires: .micRecording),
                Entry(label: text("New System Audio Recording"), keys: "⌘ ⌥ N", requires: .meetings),
                Entry(label: text("Toggle Live Captions"),       keys: "⌘ ⇧ L", requires: .liveCaptions),
                Entry(label: text("Enter Presenter Mode"),       keys: "⌘ ⇧ P", requires: .liveCaptions),
                Entry(label: text("Show Scratchpad"),            keys: "⌘ ⇧ K", requires: .dictation),
            ]),
            Section(title: text("Recording"), entries: [
                Entry(label: text("Pause or Resume Recording"),  keys: space, requires: .micRecording, .meetings),
                Entry(label: text("Add Marker"),                 keys: "⌘ B", requires: .micRecording, .meetings),
                Entry(label: text("Stop Recording"),             keys: "⌘ ↩", requires: .micRecording, .meetings),
                Entry(label: text("Cancel a Starting Recording"), keys: "Esc", requires: .micRecording, .meetings),
            ]),
            Section(title: text("Transcript"), entries: [
                Entry(label: text("Find"),                       keys: "⌘ F"),
                Entry(label: text("Export as TXT"),              keys: "⌘ E"),
                Entry(label: text("Print Transcript"),           keys: "⌘ P"),
                Entry(label: text("Focus Chat Composer"),        keys: "⌘ L", requires: .ai),
                Entry(label: text("Toggle Inspector"),           keys: "⌘ ⇧ I"),
            ]),
            Section(title: text("Playback"), entries: [
                Entry(label: text("Play / Pause"),               keys: space),
                Entry(label: text("Skip Back 5 Seconds"),        keys: "⌘ ←"),
                Entry(label: text("Skip Forward 5 Seconds"),     keys: "⌘ →"),
            ]),
            Section(title: text("Navigation"), entries: [
                Entry(label: text("Back to the List"),           keys: "⌘ ["),
                Entry(label: text("Open Settings"),              keys: "⌘ ,"),
                Entry(label: text("Open…"),                      keys: "⌘ O"),
                Entry(label: text("Search Library"),             keys: "⌘ ⌥ F"),
                Entry(label: text("Auto-Detect Language"),       keys: "⌘ ⇧ D"),
            ]),
            Section(title: text("Help"), entries: [
                Entry(label: text("Keyboard Shortcuts"),         keys: "⌘ /"),
            ]),
        ]
    }
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
