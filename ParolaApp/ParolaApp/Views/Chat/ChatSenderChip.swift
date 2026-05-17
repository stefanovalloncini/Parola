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
                    .font(.caption.weight(.semibold))
                Text(selection.label)
                    .font(DS.Font.caption)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
            }
            .padding(.horizontal, 10)
            .frame(height: 28)
            .foregroundStyle(selection == .all ? Color.primary.opacity(0.85) : Color.white)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(selection == .all ? DS.Color.surfaceElevated.opacity(0.85) : DS.Color.accent)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(DS.Color.separator.opacity(0.4), lineWidth: 0.5)
            )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Filter by sender")
    }
}
