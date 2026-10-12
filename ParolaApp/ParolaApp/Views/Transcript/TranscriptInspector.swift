import SwiftUI
import ParolaCore

/// The column beside the text, in the order you open it for; the reference rows wait closed at the bottom.
struct TranscriptInspector: View {
    @Environment(AppModel.self) private var model
    @State private var facts = TranscriptFacts()
    @AppStorage(InspectorVisibility.detailsExpandedKey, store: DefaultsStore.current) private var detailsExpanded = false
    @AppStorage(InspectorVisibility.insightsExpandedKey, store: DefaultsStore.current) private var insightsExpanded = false

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: DS.Spacing.large) {
                    OverviewSections()
                    if model.transcript != nil {
                        Divider()
                        referenceRows
                    }
                }
                .padding(DS.Spacing.regular)
            }
            .task(id: model.inspectorReveal) { await reveal(with: proxy) }
        }
        .chromeSurface()
        .task(id: model.transcriptVersion) { await recomputeFacts() }
    }

    private var referenceRows: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.regular) {
            DisclosureGroup(isExpanded: $detailsExpanded) {
                TranscriptDetails(facts: facts)
                    .padding(.top, DS.Spacing.small)
            } label: {
                // On the label: an identifier on the group would replace every one inside it.
                SectionCaption("Details")
                    .axLeaf("Inspector.Disclosure.Details")
            }
            if facts.hasInsights {
                DisclosureGroup(isExpanded: $insightsExpanded) {
                    TranscriptInsights(facts: facts)
                        .padding(.top, DS.Spacing.small)
                } label: {
                    SectionCaption("Insights")
                        .axLeaf("Inspector.Disclosure.Insights")
                }
            }
        }
    }

    private func reveal(with proxy: ScrollViewProxy) async {
        guard let section = model.inspectorReveal else { return }
        // A column that has just appeared lays its sections out on the next pass.
        await Task.yield()
        proxy.scrollTo(section, anchor: .top)
        model.inspectorReveal = nil
    }

    private func recomputeFacts() async {
        guard let transcript = model.transcript else {
            facts = TranscriptFacts()
            return
        }
        let textVersion = model.transcriptTextVersion
        let knownText = facts.textVersion == textVersion ? facts.text : nil
        let work = Task.detached(priority: .userInitiated) {
            (
                try TranscriptFacts.derive(transcript: transcript, textVersion: textVersion, knownText: knownText),
                TranscriptOutline.entries(for: transcript, chapters: [])
            )
        }
        let computed = try? await withTaskCancellationHandler {
            try await work.value
        } onCancel: {
            work.cancel()
        }
        guard let computed, !Task.isCancelled else { return }
        facts = computed.0
        model.inspectorOutline = computed.1
    }
}

/// The gist, where things are, what to do, who spoke and how it's filed, in that order.
struct OverviewSections: View {
    @Environment(AppModel.self) private var model
    /// Show Chapters keeps the section up for this transcript after its request clears, even with nothing to list.
    @State private var chaptersAsked = false

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.large) {
            if showsSummary {
                OverviewSummary()
            }
            if showsChapters {
                OverviewChapters()
                    .id(InspectorAnchor.chapters)
            }
            if OverviewActionItems.shows(model) {
                OverviewActionItems()
                    .id(InspectorAnchor.actionItems)
            }
            if !model.transcriptSpeakers.isEmpty {
                OverviewPeople()
            }
            LabelsSection()
        }
        .onChange(of: model.inspectorReveal, initial: true) { _, reveal in
            if reveal == .chapters { chaptersAsked = true }
        }
        .onChange(of: model.selectedEntryID) { chaptersAsked = false }
    }

    private var showsChapters: Bool {
        chaptersAsked || model.inspectorReveal == .chapters || OverviewChapters.shows(model)
    }

    /// The Summary pane already shows the whole summary, and a transcript with no words has nothing to sum up.
    private var showsSummary: Bool {
        model.features.isEnabled(.ai) && model.transcript != nil && !model.transcriptIsEmpty
            && model.transcriptPaneMode != .summary
    }
}

/// The ⋯ beside a section's caption, named for VoiceOver after the section it acts on.
struct SectionMenu {
    let label: LocalizedStringKey
    let leaf: String
}

/// A section caption with, when there is something to do, a ⋯ menu of the section's own actions.
struct OverviewSection<Content: View, Actions: View>: View {
    private let title: Text
    private let menu: SectionMenu?
    private let content: Content
    private let actions: Actions

    init(title: Text, menu: SectionMenu?, @ViewBuilder content: () -> Content, @ViewBuilder actions: () -> Actions) {
        self.title = title
        self.menu = menu
        self.content = content()
        self.actions = actions()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.small) {
            HStack(spacing: DS.Spacing.small) {
                SectionCaption(title)
                Spacer(minLength: 0)
                if let menu {
                    Menu {
                        actions
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .font(DS.Font.secondary)
                    }
                    .menuStyle(.button)
                    .buttonStyle(GlyphButtonStyle(side: 20))
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help(Text(menu.label))
                    .accessibilityLabel(Text(menu.label))
                    .axLeaf(menu.leaf)
                }
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension OverviewSection where Actions == EmptyView {
    init(title: Text, @ViewBuilder content: () -> Content) {
        self.init(title: title, menu: nil, content: content, actions: { EmptyView() })
    }
}

struct InspectorSection<Content: View>: View {
    private let titleText: Text
    private let content: Content

    init(title: LocalizedStringKey, @ViewBuilder content: () -> Content) {
        self.titleText = Text(title)
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.small) {
            SectionCaption(titleText)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A running AI job beside its Stop, as each section shows one.
struct OverviewProgressRow: View {
    let text: LocalizedStringKey
    let leaf: String
    let stop: () -> Void

    var body: some View {
        HStack(spacing: DS.Spacing.small) {
            ProgressView().controlSize(.small)
            Text(text)
                .font(DS.Font.body)
                .foregroundStyle(DS.Color.secondaryText)
            Spacer()
            Button("Stop", action: stop)
                .controlSize(.small)
                .axLeaf(leaf)
        }
    }
}
