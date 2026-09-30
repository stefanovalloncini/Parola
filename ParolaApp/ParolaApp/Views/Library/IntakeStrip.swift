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

    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: DS.Spacing.regular) {
            Image(systemName: "arrow.down.doc")
                .font(.system(size: 17))
                .foregroundStyle(DS.Color.accentInk)
                .accessibilityHidden(true)
            Text(verbatim: Self.prompt(linksEnabled: model.features.isEnabled(.youtube)))
                .font(DS.Font.body)
                .foregroundStyle(DS.Color.secondaryText)
                .lineLimit(1)
            Spacer(minLength: DS.Spacing.small)
            Button("Open Files…") { model.presentOpenPanel() }
                .buttonStyle(.bordered)
                .controlSize(.small)
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

    /// Auto on an English-only model runs as English, so the button says what the run will do.
    static func languageLabel(selected: String?, englishOnly: Bool, bundle: Bundle = .main) -> String {
        if let selected { return SupportedLanguages.displayName(for: selected) }
        if englishOnly { return SupportedLanguages.displayName(for: "en") }
        return String(localized: "Auto", bundle: bundle)
    }

    static func text(model: String, language: String) -> String {
        "\(model) · \(language)"
    }

    static func modelLabel(for model: AppModel) -> String {
        modelLabel(
            id: model.selectedModel,
            installedLabel: model.availableModels.first { $0.name == model.selectedModel }?.label
        )
    }

    static func languageLabel(for model: AppModel) -> String {
        languageLabel(
            selected: model.selectedLanguage,
            englishOnly: model.selectedModelCapabilities.supportedLanguages.isEnglishOnly
        )
    }
}

/// "Whisper Turbo · Auto ›": opens the popover that sets up the next run.
private struct IntakeSettingsButton: View {
    @Environment(AppModel.self) private var model
    @State private var isPresented = false

    var body: some View {
        let modelLabel = IntakeSummary.modelLabel(for: model)
        let languageLabel = IntakeSummary.languageLabel(for: model)
        Button {
            isPresented = true
        } label: {
            HStack(spacing: 3) {
                Text(verbatim: IntakeSummary.text(model: modelLabel, language: languageLabel))
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .accessibilityHidden(true)
            }
            .font(DS.Font.secondary.weight(.medium))
            .foregroundStyle(DS.Color.accentInk)
            .lineLimit(1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            IntakeSettingsPopover()
        }
        .help("Transcription settings")
        .accessibilityLabel(Text("Transcription settings"))
        .accessibilityValue(Text(verbatim: "\(modelLabel), \(languageLabel)"))
        .axLeaf("Intake.Button.Settings")
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
                        shell: .standalone,
                        popoverWidth: 400,
                        leaf: "Intake.Button.Model"
                    ) {
                        ModelPickerPopover(searchText: $modelSearch, installedOnly: $installedOnly, offersDownloads: true)
                    }
                }
                GridRow {
                    Text("Language")
                        .foregroundStyle(DS.Color.secondaryText)
                    LanguagePickerView(shell: .standalone, leaf: "Intake.Button.Language")
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
                "Identify speakers",
                detail: "Labels who is talking. Takes longer.",
                isOn: $model.diarize,
                leaf: "Intake.Toggle.IdentifySpeakers"
            )
            if model.diarize {
                Picker("Speakers", selection: $model.expectedSpeakersRaw) {
                    Text("Auto").tag(0)
                    ForEach(2...8, id: \.self) { count in
                        Text(verbatim: "\(count)").tag(count)
                    }
                }
                .font(DS.Font.body)
                .fixedSize()
                .help("How many speakers to expect. Auto lets the diarizer decide.")
                .axLeaf("Intake.Menu.ExpectedSpeakers")
            }
            if let notice = model.englishOnlyAutoNotice {
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
