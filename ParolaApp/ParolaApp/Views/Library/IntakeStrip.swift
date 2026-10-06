import SwiftUI
import ParolaCore

/// The whole window takes a drop; the strip says so, beside Open Files and the next run's settings.
struct IntakeStrip: View {
    static let height: CGFloat = 44

    static func prompt(linksEnabled: Bool, bundle: Bundle = .main) -> String {
        linksEnabled
            ? String(localized: "Drop audio or video, or paste a link", bundle: bundle)
            : String(localized: "Drop audio or video", bundle: bundle)
    }

    // Optional: AppKit can build a List cell after SwiftUI tore the List down, and a required read traps "No Observable object of type AppModel found".
    @Environment(AppModel.self) private var model: AppModel?

    var body: some View {
        HStack(spacing: DS.Spacing.regular) {
            Image(systemName: "arrow.down.doc")
                .font(.system(size: 17))
                .foregroundStyle(DS.Color.accentInk)
                .accessibilityHidden(true)
            Text(verbatim: Self.prompt(linksEnabled: model?.features.isEnabled(.youtube) == true))
                .font(DS.Font.body)
                .foregroundStyle(DS.Color.secondaryText)
                .lineLimit(1)
            Spacer(minLength: DS.Spacing.small)
            Button("Open Files…") { model?.presentOpenPanel() }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(nil)
                .fixedSize()
                .axLeaf("Intake.Button.OpenFiles")
            IntakeSettingsButton()
        }
        .padding(.horizontal, DS.Spacing.medium)
        .frame(height: Self.height)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.regular, style: .continuous)
                .fill(DS.Color.surfaceElevated)
        )
    }
}

/// What the next run will use, in the words the button shows.
@MainActor
enum IntakeSummary {
    static func modelLabel(id: String, installedLabel: String?) -> String {
        if let variant = ModelCatalog.variant(id: id) { return ModelPickerView.shortLabel(for: variant.displayName) }
        return ModelPickerView.capped(installedLabel ?? id)
    }

    /// Auto on an English-only model runs as English, so the button says what the run will do; the hero has room to spell Auto out.
    static func languageLabel(selected: String?, englishOnly: Bool, spellsOutAuto: Bool = false, bundle: Bundle = .main) -> String {
        if let selected { return SupportedLanguages.displayName(for: selected) }
        if englishOnly { return SupportedLanguages.displayName(for: "en") }
        return spellsOutAuto ? String(localized: "Auto-detect", bundle: bundle) : String(localized: "Auto", bundle: bundle)
    }

    /// Anything that changes what the transcript says is named here, since the popover is the only other place it shows.
    static func parts(
        model: String,
        language: String,
        translates: Bool,
        identifiesSpeakers: Bool,
        bundle: Bundle = .main
    ) -> [String] {
        var parts = [model, language]
        // Keys of their own: the shared Translate and Speakers read as a verb and as people in Italian.
        if translates { parts.append(String(localized: "Intake.Option.Translate", defaultValue: "Translate", bundle: bundle)) }
        if identifiesSpeakers { parts.append(String(localized: "Intake.Option.Speakers", defaultValue: "Speakers", bundle: bundle)) }
        return parts
    }

    static func text(
        model: String,
        language: String,
        translates: Bool,
        identifiesSpeakers: Bool,
        bundle: Bundle = .main
    ) -> String {
        parts(
            model: model, language: language, translates: translates, identifiesSpeakers: identifiesSpeakers, bundle: bundle
        ).joined(separator: " · ")
    }

    /// Translate is named only while the chosen model can translate: otherwise the run stays in its own language.
    static func parts(for model: AppModel, spellsOutAuto: Bool = false) -> [String] {
        parts(
            model: modelLabel(for: model),
            language: languageLabel(for: model, spellsOutAuto: spellsOutAuto),
            translates: model.translate && model.selectedModelCapabilities.supportsTranslate,
            identifiesSpeakers: model.diarize
        )
    }

    static func text(for model: AppModel) -> String {
        parts(for: model).joined(separator: " · ")
    }

    static func modelLabel(for model: AppModel) -> String {
        modelLabel(
            id: model.selectedModel,
            installedLabel: model.availableModels.first { $0.name == model.selectedModel }?.label
        )
    }

    static func languageLabel(for model: AppModel, spellsOutAuto: Bool = false) -> String {
        languageLabel(
            selected: model.selectedLanguage,
            englishOnly: model.selectedModelCapabilities.supportedLanguages.isEnglishOnly,
            spellsOutAuto: spellsOutAuto
        )
    }

    /// At most one applies: the English-only note needs Auto, the mismatch warning a picked language.
    static func languageNotice(for model: AppModel) -> String? {
        model.englishOnlyAutoNotice ?? model.languageMismatchWarning
    }
}

/// "Whisper Turbo · Auto ›": opens the popover that sets up the next run. Accent in the strip, quiet under the hero.
struct IntakeSettingsButton: View {
    enum Style {
        case accent
        case quiet
    }

    var style: Style = .accent
    var leaf = "Intake.Button.Settings"

    // Optional: AppKit can build a List cell after SwiftUI tore the List down, and a required read traps "No Observable object of type AppModel found".
    @Environment(AppModel.self) private var model: AppModel?
    @State private var isPresented = false

    var body: some View {
        let parts = model.map { IntakeSummary.parts(for: $0, spellsOutAuto: style == .quiet) } ?? []
        Button {
            isPresented = true
        } label: {
            HStack(spacing: 3) {
                Text(verbatim: parts.joined(separator: " · "))
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .accessibilityHidden(true)
            }
            .font(style == .accent ? DS.Font.secondary.weight(.medium) : DS.Font.secondary)
            .foregroundStyle(style == .accent ? DS.Color.accentInk : DS.Color.secondaryText)
            .lineLimit(1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(model == nil)
        .fixedSize()
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            IntakeSettingsPopover()
        }
        .help("Transcription settings")
        .accessibilityLabel(Text("Transcription settings"))
        .accessibilityValue(Text(verbatim: parts.joined(separator: ", ")))
        .axLeaf(leaf)
    }
}

struct IntakeSettingsPopover: View {
    @Environment(AppModel.self) private var model
    @State private var modelSearch = ""
    @State private var installedOnly = false

    var body: some View {
        @Bindable var model = model
        return VStack(alignment: .leading, spacing: DS.Spacing.regular) {
            Grid(alignment: .leading, horizontalSpacing: DS.Spacing.regular, verticalSpacing: DS.Spacing.small) {
                GridRow {
                    Text("Model")
                        .foregroundStyle(DS.Color.secondaryText)
                        .gridColumnAlignment(.trailing)
                    PillPickerButton(
                        icon: "cpu",
                        caption: String(localized: "Model"),
                        value: IntakeSummary.modelLabel(for: model),
                        popoverWidth: 400,
                        leaf: "Intake.Button.Model"
                    ) {
                        ModelPickerPopover(searchText: $modelSearch, installedOnly: $installedOnly, offersDownloads: true)
                    }
                }
                GridRow {
                    Text("Language")
                        .foregroundStyle(DS.Color.secondaryText)
                    LanguagePickerView(leaf: "Intake.Button.Language")
                        .disabled(model.selectedModelCapabilities.supportedLanguages.isEnglishOnly)
                }
            }
            .font(DS.Font.body)

            Divider()

            if model.selectedModelCapabilities.supportsTranslate {
                switchRow(
                    "Translate to English",
                    detail: "Writes the transcript in English, whatever was spoken.",
                    isOn: $model.translate,
                    leaf: "Intake.Toggle.Translate"
                )
            }
            switchRow(
                "Detect speakers",
                detail: "Labels who is talking. Takes longer.",
                isOn: $model.diarize,
                leaf: "Intake.Toggle.IdentifySpeakers"
            )
            if model.diarize {
                Picker("Number of speakers", selection: $model.expectedSpeakersRaw) {
                    Text("Auto").tag(0)
                    ForEach(2...8, id: \.self) { count in
                        Text(verbatim: "\(count)").tag(count)
                    }
                }
                .font(DS.Font.body)
                .fixedSize()
                .help("How many speakers to expect. Auto lets Parola decide.")
                .axLeaf("Intake.Menu.ExpectedSpeakers")
            }
            if let notice = IntakeSummary.languageNotice(for: model) {
                Label(notice, systemImage: "exclamationmark.triangle.fill")
                    .font(DS.Font.secondary)
                    .foregroundStyle(DS.Color.warningText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .controlSize(.small)
        .padding(DS.Spacing.medium)
        .frame(width: 320)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Transcription settings"))
        .axLeaf("Intake.Popover")
    }

    private func switchRow(
        _ title: LocalizedStringKey,
        detail: LocalizedStringKey,
        isOn: Binding<Bool>,
        leaf: String
    ) -> some View {
        HStack(alignment: .top, spacing: DS.Spacing.regular) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(DS.Font.body)
                    .foregroundStyle(DS.Color.primaryText)
                Text(detail)
                    .font(DS.Font.secondary)
                    .foregroundStyle(DS.Color.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Toggle(isOn: isOn) { Text(title) }
                .toggleStyle(.switch)
                .labelsHidden()
                .axLeaf(leaf)
        }
    }
}
