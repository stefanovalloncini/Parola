import SwiftUI
import ParolaCore

struct LanguagePickerView: View {
    @Environment(AppModel.self) private var model
    var leaf: String? = nil
    @State private var searchText = ""

    var body: some View {
        PillPickerButton(icon: "globe", caption: String(localized: "Language"), value: currentLabel, popoverWidth: 300, leaf: leaf) {
            LanguagePickerPopover(searchText: $searchText)
        }
    }

    private var currentLabel: String {
        guard let code = model.selectedLanguage else {
            // Auto on an English-only model runs as English regardless (TranscriptionSession pins
            // it); showing that here beats a label that's true about the setting but not the run.
            return model.selectedModelCapabilities.supportedLanguages.isEnglishOnly
                ? SupportedLanguages.displayName(for: "en") : LanguagePickerPopover.autoLabel
        }
        return SupportedLanguages.displayName(for: code)
    }
}

/// The model's own languages, led by the Mac's and the library's recent ones, with a search field as the model popover has.
struct LanguagePickerPopover: View {
    @Environment(AppModel.self) private var model
    @Binding var searchText: String

    static var autoLabel: String { String(localized: "Auto-detect") }

    var body: some View {
        VStack(spacing: 0) {
            SearchPill(text: $searchText, placeholder: "Search languages", leaf: "LanguagePicker.TextField.Search")
                .padding(.horizontal, DS.Spacing.small)
                .padding(.top, DS.Spacing.tight)
                .padding(.bottom, DS.Spacing.snug)
            PillPopoverRow(
                title: Self.autoLabel,
                subtitle: String(localized: "Identified from the audio"),
                isSelected: model.selectedLanguage == nil,
                leading: .symbol("waveform.badge.magnifyingglass", tint: DS.Color.accent),
                minHeight: PillPopoverRow.twoLineHeight,
                action: { model.selectedLanguage = nil }
            )
            Divider()
                .padding(.horizontal, DS.Spacing.small)
                .padding(.vertical, DS.Spacing.tight)
            PillPopoverList {
                let sections = LanguageChoices.sections(
                    scope: scope,
                    leading: LanguageChoices.leading(model: model),
                    query: searchText,
                    name: SupportedLanguages.displayName(for:)
                )
                if sections.top.isEmpty, sections.rest.isEmpty {
                    Text("No languages match")
                        .font(DS.Font.caption)
                        .foregroundStyle(DS.Color.secondaryText)
                        .padding(.horizontal, DS.Spacing.regular)
                        .padding(.vertical, DS.Spacing.small)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                ForEach(sections.top, id: \.self) { code in row(code) }
                if !sections.top.isEmpty, !sections.rest.isEmpty {
                    Divider()
                        .padding(.horizontal, DS.Spacing.small)
                        .padding(.vertical, DS.Spacing.tight)
                }
                ForEach(sections.rest, id: \.self) { code in row(code) }
            }
        }
        .padding(.horizontal, DS.Spacing.snug)
        .task(id: model.selectedModel) {
            guard LanguageChoices.engine(of: model.selectedModel) == .appleSpeech else { return }
            await model.loadAppleSpeechLanguages()
        }
    }

    private func row(_ code: String) -> some View {
        let note = Self.supportNote(for: code, scope: scope, modelName: modelName)
        return PillPopoverRow(
            title: SupportedLanguages.displayName(for: code),
            subtitle: note ?? SupportedLanguages.endonym(for: code),
            subtitleTint: note == nil ? nil : DS.Color.warningText,
            isSelected: code == model.selectedLanguage,
            isDimmed: note != nil,
            leading: .monogram(code.uppercased()),
            minHeight: PillPopoverRow.twoLineHeight,
            action: { model.selectedLanguage = code }
        )
    }

    /// A pick the model can't honour still goes through (the intake popover warns), but the row says so first.
    static func supportNote(for code: String, scope: ParolaCore.SupportedLanguages, modelName: String) -> String? {
        scope.allows(code) ? nil : String(localized: "Not supported by \(modelName)")
    }

    private var scope: ParolaCore.SupportedLanguages {
        LanguageChoices.scope(model: model)
    }

    private var modelName: String {
        guard let variant = ModelCatalog.variant(id: model.selectedModel) else { return model.selectedModel }
        return ModelPickerView.shortLabel(for: variant.displayName)
    }
}

/// What a language picker lists for the model in use, and in what order.
enum LanguageChoices {
    static func engine(of modelID: String) -> EngineID {
        ModelCatalog.variant(id: modelID)?.engineID ?? .whisperKit
    }

    /// Only Whisper takes Whisper's whole list; Apple Speech takes the locales it reports, and the short list until then.
    static func scope(
        _ scope: ParolaCore.SupportedLanguages, engine: EngineID, appleSpeech: Set<String>?
    ) -> ParolaCore.SupportedLanguages {
        guard case .all = scope, engine != .whisperKit else { return scope }
        if engine == .appleSpeech, let appleSpeech, !appleSpeech.isEmpty { return .only(appleSpeech) }
        return .only(Set(SupportedLanguages.codes))
    }

    @MainActor
    static func scope(model: AppModel) -> ParolaCore.SupportedLanguages {
        scope(
            model.selectedModelCapabilities.supportedLanguages,
            engine: engine(of: model.selectedModel),
            appleSpeech: model.appleSpeechLanguageCodes
        )
    }

    /// A Whisper model, which takes any language, is offered every one Whisper was trained on.
    static func supported(by scope: ParolaCore.SupportedLanguages) -> Set<String> {
        switch scope {
        case .all: WhisperLanguages.codes
        case .only(let codes): codes
        }
    }

    /// `leading` comes first whether or not the model takes it, so a pick it can't honour still shows with its note.
    static func sections(
        scope: ParolaCore.SupportedLanguages, leading: [String], query: String, name: (String) -> String
    ) -> (top: [String], rest: [String]) {
        var seen = Set<String>()
        let top = leading.filter { seen.insert($0).inserted }
        let rest = supported(by: scope).subtracting(seen).sorted {
            name($0).localizedStandardCompare(name($1)) == .orderedAscending
        }
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return (top, rest) }
        let matches = { (code: String) in
            code.caseInsensitiveCompare(query) == .orderedSame || name(code).localizedStandardContains(query)
        }
        return (top.filter(matches), rest.filter(matches))
    }

    /// The pick in use, the Mac's own languages, then the last few the library was transcribed in.
    @MainActor
    static func leading(model: AppModel) -> [String] {
        let system = Locale.preferredLanguages.compactMap { Locale(identifier: $0).language.languageCode?.identifier }
        var recent: [String] = []
        for entry in model.libraryEntries.sorted(by: { $0.createdAt > $1.createdAt }) {
            guard let code = LanguageDisplay.code(for: entry.language)?.lowercased(), !recent.contains(code) else { continue }
            recent.append(code)
            if recent.count == recentLimit { break }
        }
        return [model.selectedLanguage].compactMap { $0 } + system + recent
    }

    static let recentLimit = 3
}
