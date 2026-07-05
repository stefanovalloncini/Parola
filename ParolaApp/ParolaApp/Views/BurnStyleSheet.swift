import SwiftUI
import ParolaCore

struct BurnStyleSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        SheetFrame(
            icon: "film",
            title: "Burn subtitles into video",
            onClose: { dismiss() },
            content: { contentBody },
            footer: { footerBody }
        )
    }

    private var contentBody: some View {
        @Bindable var model = model
        return VStack(alignment: .leading, spacing: DS.Spacing.regular) {
            Text("Captions are rendered permanently into a copy of the video.")
                .font(DS.Font.body)
                .foregroundStyle(DS.Color.secondaryText)
                .fixedSize(horizontal: false, vertical: true)

            optionRow("Font size") {
                Picker("", selection: $model.burnFontSizeRaw) {
                    ForEach(BurnFontSize.allCases) { size in
                        Text(size.displayName).tag(size.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 220)
                .axLeaf("BurnStyle.Picker.FontSize")
            }

            optionRow("Text color") {
                Picker("", selection: $model.burnTextColorRaw) {
                    ForEach(BurnTextColor.allCases) { color in
                        Text(color.displayName).tag(color.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 220)
                .axLeaf("BurnStyle.Picker.TextColor")
            }

            optionRow("Outline") {
                Toggle("", isOn: $model.burnOutline)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .tint(DS.Color.accent)
                    .axLeaf("BurnStyle.Toggle.Outline")
            }
        }
        .padding(DS.Spacing.regular)
    }

    private func optionRow(_ title: LocalizedStringKey, @ViewBuilder control: () -> some View) -> some View {
        HStack {
            Text(title)
                .font(DS.Font.body)
                .foregroundStyle(DS.Color.primaryText)
            Spacer()
            control()
                .labelsHidden()
        }
    }

    private var footerBody: some View {
        HStack(spacing: DS.Spacing.small) {
            Button("Cancel") { dismiss() }
                .sheetSecondaryAction()
                .keyboardShortcut(.cancelAction)
                .axLeaf("BurnStyle.Button.Cancel")

            Spacer()

            Button("Choose Video…") {
                dismiss()
                model.burnSubtitlesIntoVideo()
            }
            .sheetPrimaryAction()
            .keyboardShortcut(.defaultAction)
            .axLeaf("BurnStyle.Button.ChooseVideo")
        }
    }
}
