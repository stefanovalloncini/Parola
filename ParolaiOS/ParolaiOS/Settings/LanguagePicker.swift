import SwiftUI

struct LanguageOption: Hashable, Identifiable, Sendable {
    let code: String?
    let labelKey: String
    var id: String { code ?? "auto" }
    var label: LocalizedStringKey { LocalizedStringKey(labelKey) }
}

enum LanguageCatalog {
    static let auto = LanguageOption(code: nil, labelKey: "language.auto")

    static let common: [LanguageOption] = [
        LanguageOption(code: "en", labelKey: "language.en"),
        LanguageOption(code: "it", labelKey: "language.it"),
        LanguageOption(code: "es", labelKey: "language.es"),
        LanguageOption(code: "fr", labelKey: "language.fr"),
        LanguageOption(code: "de", labelKey: "language.de"),
        LanguageOption(code: "pt", labelKey: "language.pt")
    ]

    static let extended: [LanguageOption] = common + [
        LanguageOption(code: "nl", labelKey: "language.nl"),
        LanguageOption(code: "ru", labelKey: "language.ru"),
        LanguageOption(code: "pl", labelKey: "language.pl"),
        LanguageOption(code: "sv", labelKey: "language.sv"),
        LanguageOption(code: "tr", labelKey: "language.tr"),
        LanguageOption(code: "ar", labelKey: "language.ar"),
        LanguageOption(code: "ja", labelKey: "language.ja"),
        LanguageOption(code: "zh", labelKey: "language.zh"),
        LanguageOption(code: "ko", labelKey: "language.ko"),
        LanguageOption(code: "hi", labelKey: "language.hi")
    ]

    static func label(for code: String?) -> LocalizedStringKey {
        if code == nil { return auto.label }
        return extended.first(where: { $0.code == code })?.label ?? LocalizedStringKey("language.unknown")
    }
}

struct LanguagePicker: View {
    @Binding var selection: String?
    let compact: Bool
    @State private var showingFullList = false

    var body: some View {
        if compact {
            compactPicker
        } else {
            fullList
        }
    }

    private var compactPicker: some View {
        VStack(alignment: .leading, spacing: 12) {
            optionRow(LanguageCatalog.auto)
            ForEach(LanguageCatalog.common) { option in
                optionRow(option)
            }
            Button {
                showingFullList = true
            } label: {
                HStack {
                    Text("language.more")
                        .font(.body.weight(.medium))
                        .foregroundStyle(.primary)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .padding(.vertical, 10)
                .padding(.horizontal, 14)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color(.secondarySystemBackground))
                )
            }
            .buttonStyle(.plain)
        }
        .sheet(isPresented: $showingFullList) {
            NavigationStack {
                fullList
                    .navigationTitle(Text("language.choose"))
                    .navigationBarTitleDisplayMode(.inline)
            }
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
        }
    }

    private var fullList: some View {
        List {
            Section {
                fullListRow(LanguageCatalog.auto)
            }
            Section {
                ForEach(LanguageCatalog.extended) { option in
                    fullListRow(option)
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    private func optionRow(_ option: LanguageOption) -> some View {
        Button {
            selection = option.code
        } label: {
            HStack {
                Text(option.label)
                    .font(.body)
                    .foregroundStyle(.primary)
                Spacer()
                if option.code == selection {
                    Image(systemName: "checkmark")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 14)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(option.code == selection ? Color.accentColor.opacity(0.08) : Color(.secondarySystemBackground))
            )
        }
        .buttonStyle(.plain)
        .animation(.spring(response: 0.3, dampingFraction: 0.75), value: selection)
    }

    private func fullListRow(_ option: LanguageOption) -> some View {
        Button {
            selection = option.code
        } label: {
            HStack {
                Text(option.label)
                Spacer()
                if option.code == selection {
                    Image(systemName: "checkmark")
                        .foregroundStyle(Color.accentColor)
                }
            }
        }
        .foregroundStyle(.primary)
    }
}
