import SwiftUI

struct ChatSenderChip: View {
    @Binding var selection: ChatSenderFilter

    var body: some View {
        Menu {
            ForEach(ChatSenderFilter.allCases, id: \.self) { option in
                Button {
                    selection = option
                } label: {
                    if option == selection {
                        Label(option.label, systemImage: "checkmark")
                    } else {
                        Text(option.label)
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "person.crop.circle")
                    .font(DS.Font.captionEmphasized)
                Text(selection.label)
                    .font(DS.Font.secondary)
                Image(systemName: "chevron.down")
                    .font(DS.Font.caption2Emphasized)
            }
        }
        .menuStyle(.button)
        .buttonStyle(SenderChipButtonStyle(isFiltered: selection != .all))
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Filter by sender")
    }
}

/// The chip's own chrome as a style: `.borderlessButton` hands the label to AppKit, which drops it.
private struct SenderChipButtonStyle: ButtonStyle {
    let isFiltered: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 10)
            .frame(height: 28)
            .foregroundStyle(isFiltered ? DS.Color.onAccent : Color.primary.opacity(0.85))
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.large, style: .continuous)
                    .fill(isFiltered ? DS.Color.accent : DS.Color.surfaceElevated.opacity(0.85))
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.large, style: .continuous)
                    .stroke(DS.Color.separator.opacity(0.4), lineWidth: 0.5)
            )
            .opacity(configuration.isPressed ? 0.85 : 1)
            .contentShape(RoundedRectangle(cornerRadius: DS.Radius.large, style: .continuous))
    }
}
