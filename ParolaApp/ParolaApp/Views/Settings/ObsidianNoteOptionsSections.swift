import SwiftUI
import ParolaCore

/// The frontmatter and note-body switches both Obsidian destinations share.
struct ObsidianNoteOptionsSections: View {
    @Binding var frontmatter: ObsidianFrontmatterOptions
    @Binding var noteBody: ObsidianBodyOptions
    @Binding var wikilinks: Bool

    var body: some View {
        Group {
            frontmatterSection
            bodySection
        }
    }

    private var frontmatterSection: some View {
        SettingsSection("Frontmatter") {
            toggleRow("Title", isOn: $frontmatter.title, leaf: "Title")
            toggleRow("Date", isOn: $frontmatter.date, leaf: "Date")
            toggleRow("Duration", isOn: $frontmatter.duration, leaf: "Duration")
            toggleRow("Source", isOn: $frontmatter.source, leaf: "Source")
            toggleRow("Language", isOn: $frontmatter.language, leaf: "Language")
            toggleRow("Model", isOn: $frontmatter.model, leaf: "Model")
            toggleRow("Speakers", isOn: $frontmatter.speakers, leaf: "FrontmatterSpeakers")
            toggleRow("Tags", isOn: $frontmatter.tags, leaf: "Tags")
            toggleRow("Summary", isOn: $frontmatter.summary, leaf: "FrontmatterSummary")
        }
    }

    private var bodySection: some View {
        SettingsSection("Note body") {
            toggleRow("Summary", isOn: $noteBody.summary, leaf: "BodySummary")
            toggleRow("Transcript", isOn: $noteBody.transcript, leaf: "BodyTranscript")
            toggleRow("Timestamps", isOn: $noteBody.timestamps, leaf: "BodyTimestamps")
            toggleRow("Speaker names", isOn: $noteBody.speakers, leaf: "BodySpeakers")
            toggleRow("Favorites", isOn: $noteBody.favorites, leaf: "BodyFavorites")
            SettingRow("Link speaker names", description: "Writes a speaker as [[Name]] so Obsidian links the note to a person.") {
                Toggle("", isOn: $wikilinks)
                    .labelsHidden()
                    .axLeaf("SendTo.Toggle.Wikilinks")
            }
        }
    }

    private func toggleRow(_ title: LocalizedStringKey, isOn: Binding<Bool>, leaf: String) -> some View {
        SettingRow(title) {
            Toggle("", isOn: isOn)
                .labelsHidden()
                .axLeaf("SendTo.Toggle.\(leaf)")
        }
    }
}
