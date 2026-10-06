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

    static func sections(
        features: FeatureSet, exportPreset: ExportPreset? = ExportPreset.builtIns.first, bundle: Bundle = .main
    ) -> [Section] {
        allSections(exportPreset: exportPreset, bundle: bundle).compactMap { section in
            let entries = section.entries.filter { entry in
                entry.requires.isEmpty || entry.requires.contains(where: features.isEnabled)
            }
            return entries.isEmpty ? nil : Section(title: section.title, entries: entries)
        }
    }

    /// A built-in preset's name is a catalog key; a name the user typed is shown as typed.
    private static func presetName(_ preset: ExportPreset, bundle: Bundle) -> String {
        preset.isBuiltIn ? bundle.localizedString(forKey: preset.name, value: nil, table: nil) : preset.name
    }

    private static func allSections(exportPreset: ExportPreset?, bundle: Bundle) -> [Section] {
        func text(_ key: String.LocalizationValue) -> String { String(localized: key, bundle: bundle) }
        let space = text("Space")
        // ⌘E runs whichever preset tops Export As, so the line is named for that one.
        let exportOnE = exportPreset.map { Entry(label: text("Export as \(presetName($0, bundle: bundle))"), keys: "⌘ E") }
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
                Entry(label: text("Show Transcript"),            keys: "⌘ 1"),
                Entry(label: text("Show Summary"),               keys: "⌘ 2", requires: .ai),
                Entry(label: text("Show Chat"),                  keys: "⌘ 3", requires: .ai),
                Entry(label: text("Paragraphs"),                 keys: "⌘ ⌃ 1"),
                Entry(label: text("Segments"),                   keys: "⌘ ⌃ 2"),
                Entry(label: text("Next Segment"),               keys: "⌘ ⌥ ↓"),
                Entry(label: text("Previous Segment"),           keys: "⌘ ⌥ ↑"),
                Entry(label: text("Jump to Next Speaker"),       keys: "⌘ ⇧ J"),
                Entry(label: text("Jump to Time…"),              keys: "⌘ J"),
                Entry(label: text("Show Outline"),               keys: "⌘ ⇧ O"),
                Entry(label: text("Favorite Segment"),           keys: "⌘ D"),
                Entry(label: text("Auto-Detect Language"),       keys: "⌘ ⇧ D"),
                Entry(label: text("Show or Hide Inspector"),     keys: "⌘ ⇧ I"),
                Entry(label: text("Focus Chat Composer"),        keys: "⌘ L", requires: .ai),
                Entry(label: text("Open in New Window"),         keys: "⌘ ⇧ N"),
            ]),
            Section(title: text("Find"), entries: [
                Entry(label: text("Find"),                       keys: "⌘ F"),
                Entry(label: text("Find Next"),                  keys: "⌘ G"),
                Entry(label: text("Find Previous"),              keys: "⌘ ⇧ G"),
                Entry(label: text("Replace"),                    keys: "⌘ ="),
                Entry(label: text("Replace All"),                keys: "⌘ ⌥ E"),
            ]),
            Section(title: text("Copy and Export"), entries: [
                Entry(label: text("Copy Transcript"),            keys: "⌘ ⇧ C"),
                Entry(label: text("Copy with Timestamps"),       keys: "⌘ ⌥ C"),
                Entry(label: text("Export…"),                    keys: "⌘ ⇧ E"),
            ] + [exportOnE].compactMap { $0 } + [
                Entry(label: text("Send via Mail…"),             keys: "⌘ ⇧ M"),
                Entry(label: text("Print Transcript"),           keys: "⌘ P"),
                Entry(label: text("Save As Parola Document…"),   keys: "⌘ S"),
            ]),
            Section(title: text("Playback"), entries: [
                Entry(label: text("Play / Pause"),               keys: space),
                Entry(label: text("Skip Back 5 Seconds"),        keys: "⌘ ←"),
                Entry(label: text("Skip Forward 5 Seconds"),     keys: "⌘ →"),
                Entry(label: text("Show Mini Player"),           keys: "⌘ ⌥ M"),
            ]),
            Section(title: text("Navigation"), entries: [
                Entry(label: text("Back to the List"),           keys: "⌘ ["),
                Entry(label: text("Open Settings"),              keys: "⌘ ,"),
                Entry(label: text("Open Files…"),                keys: "⌘ O"),
                Entry(label: text("Search Library"),             keys: "⌘ ⌥ F"),
            ]),
            Section(title: text("Go"), entries: [
                Entry(label: text("Library"),                    keys: "⌘ ⌥ 1"),
                Entry(label: text("Transcriptions"),             keys: "⌘ ⌥ 2"),
                Entry(label: text("Meetings"),                   keys: "⌘ ⌥ 3", requires: .meetings),
                Entry(label: text("Dictations"),                 keys: "⌘ ⌥ 4", requires: .dictation),
                Entry(label: text("Activity"),                   keys: "⌘ ⌥ 5"),
                Entry(label: text("Recently Deleted"),           keys: "⌘ ⌥ 6"),
                Entry(label: text("Statistics"),                 keys: "⌘ ⌥ 7"),
                Entry(label: text("Show or Hide Sidebar"),       keys: "⌘ ⌃ S"),
            ]),
            Section(title: text("Library"), entries: [
                Entry(label: text("Move to Recently Deleted"),   keys: "⌘ ⌫"),
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
                    ForEach(ShortcutCatalog.sections(features: model.features, exportPreset: model.exportPresets.first)) { section in
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
