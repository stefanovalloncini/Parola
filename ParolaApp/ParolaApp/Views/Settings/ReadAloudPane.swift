import SwiftUI
import ParolaCore

struct ReadAloudPane: View {
    @Environment(AppModel.self) private var model
    @State private var personalStatus = PersonalVoiceStatus.unsupported

    var body: some View {
        @Bindable var model = model
        return SettingsForm {
            voicesSection
            personalVoiceSection
            SettingsSection("Playback") {
                SettingRow("Speed", description: "How fast Parola reads. The reading toolbar menu changes the same setting.") {
                    Picker("Speed", selection: $model.readAloudRate) {
                        ForEach(ReadAloudController.speeds, id: \.self) { rate in
                            Text(Self.speedLabel(rate)).tag(rate)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .axLeaf("ReadAloud.Picker.Speed")
                }
            }
            ResetPaneButton(scope: .readAloud)
        }
        .task { personalStatus = model.readAloud.personalVoiceStatus }
    }

    static func speedLabel(_ rate: Double) -> String {
        let text = rate.formatted(.number.precision(.fractionLength(0...2)))
        return "\(text)×"
    }

    private var languages: [String] {
        let translations = [model.transcript?.translation?.targetLanguage].compactMap { $0 } + (model.translate ? ["en"] : [])
        return ReadAloudVoices.rows(
            known: model.knownLanguages(in: nil),
            saved: Array(model.readAloudVoices.keys),
            interface: Bundle.main.preferredLocalizations.first ?? "en",
            translations: translations
        )
    }

    private var voicesSection: some View {
        Section {
            ForEach(languages, id: \.self) { language in
                ReadAloudVoiceRow(language: language)
            }
        } header: {
            Text("Voices")
        } footer: {
            HStack {
                Button("Get more voices…") { model.openMoreVoices() }
                    .axLeaf("ReadAloud.Button.MoreVoices")
                Spacer(minLength: 0)
            }
        }
    }

    @ViewBuilder
    private var personalVoiceSection: some View {
        let personalVoices = model.readAloud.appleInventory.voices.filter(\.isPersonal).count
        switch ReadAloudVoices.personalVoice(status: personalStatus, personalVoices: personalVoices) {
        case .hidden:
            EmptyView()
        case .askButton:
            SettingsSection("Personal Voice") {
                SettingRow("Read in a voice you made", description: "macOS asks before Parola can use a Personal Voice from this Mac.") {
                    Button("Use Personal Voice…") {
                        Task {
                            await model.requestPersonalVoice()
                            personalStatus = model.readAloud.personalVoiceStatus
                        }
                    }
                    .axLeaf("ReadAloud.Button.PersonalVoice")
                }
            }
        case .deniedNote:
            SettingsSection("Personal Voice") {
                Text("Parola can't use your Personal Voice. Allow it in System Settings, under Privacy & Security.")
                    .foregroundStyle(DS.Color.secondaryText)
                    .axLeaf("ReadAloud.Text.PersonalVoiceDenied")
            }
        case .granted(let count):
            SettingsSection("Personal Voice") {
                Text(count == 0
                    ? "Personal Voice is on. You have none on this Mac yet."
                    : "Personal Voice is on. Your voices are in each language's list.")
                    .foregroundStyle(DS.Color.secondaryText)
                    .axLeaf("ReadAloud.Text.PersonalVoiceOn")
            }
        }
    }
}

private struct ReadAloudVoiceRow: View {
    let language: String
    @Environment(AppModel.self) private var model

    private var entries: [VoiceMenuEntry] {
        ReadAloudVoices.settingsEntries(
            for: language, in: model.readAloud.appleInventory, saved: model.readAloudVoices[ReadAloudVoices.key(for: language)]
        )
    }

    private var name: String {
        LanguageDisplay.name(for: language) ?? language
    }

    private var selection: Binding<VoiceID> {
        Binding(
            get: {
                let saved = model.readAloudVoices[ReadAloudVoices.key(for: language)]
                guard let saved, entries.contains(where: { $0.voice == saved }) else { return .appleAutomatic }
                return saved
            },
            set: { model.readAloudVoices[ReadAloudVoices.key(for: language)] = $0 }
        )
    }

    var body: some View {
        LabeledContent {
            if entries.isEmpty {
                Text("No voice on this Mac reads \(LanguageDisplay.midSentenceName(for: language) ?? language).")
                    .foregroundStyle(DS.Color.secondaryText)
                    .multilineTextAlignment(.trailing)
                    .axLeaf("ReadAloud.Text.NoVoice.\(language)")
            } else {
                HStack(spacing: DS.Spacing.small) {
                    Picker(name, selection: selection) {
                        ForEach(entries) { entry in
                            Text(entry.title).tag(entry.voice).disabled(!entry.isUsable)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .axLeaf("ReadAloud.Picker.Voice.\(language)")
                    previewButton
                }
            }
        } label: {
            Text(name)
        }
    }

    @ViewBuilder
    private var previewButton: some View {
        if model.readAloud.previewing != nil {
            Button("Stop") { Task { await model.readAloud.stopPreview() } }
                .axLeaf("ReadAloud.Button.StopPreview.\(language)")
        } else {
            Button("Preview") { Task { await model.previewVoice(selection.wrappedValue, language: language) } }
                .disabled(model.readingBlockedReason != nil)
                .axLeaf("ReadAloud.Button.Preview.\(language)")
        }
    }
}
