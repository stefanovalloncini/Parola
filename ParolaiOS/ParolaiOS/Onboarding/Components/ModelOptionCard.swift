import SwiftUI

struct ModelOptionCard: View {
    let choice: ModelChoice
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(alignment: .top, spacing: 12) {
                selectionDot
                    .padding(.top, 2)

                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(choice.label)
                            .font(.headline)
                            .foregroundStyle(.primary)
                        Text("\(choice.sizeMB) MB")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                    }

                    Text(choice.description)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 14) {
                        IndicatorRow(
                            labelKey: "onboarding.model.indicator.speed",
                            filled: choice.speed,
                            symbol: "bolt.fill"
                        )
                        IndicatorRow(
                            labelKey: "onboarding.model.indicator.accuracy",
                            filled: choice.accuracy,
                            symbol: "circle.fill"
                        )
                    }
                    .padding(.top, 2)
                }
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(isSelected ? Color.accentColor.opacity(0.08) : Color(.secondarySystemBackground))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 1.5)
            )
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var selectionDot: some View {
        ZStack {
            Circle()
                .strokeBorder(isSelected ? Color.accentColor : Color.secondary.opacity(0.4), lineWidth: 1.5)
                .frame(width: 22, height: 22)
            if isSelected {
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 12, height: 12)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isSelected)
    }
}

struct IndicatorRow: View {
    let labelKey: LocalizedStringKey
    let filled: Int
    let symbol: String

    var body: some View {
        HStack(spacing: 6) {
            Text(labelKey)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.tertiary)
                .textCase(.uppercase)
            HStack(spacing: 3) {
                ForEach(1...3, id: \.self) { i in
                    Image(systemName: symbol)
                        .font(.system(size: 8))
                        .foregroundStyle(i <= filled ? Color.accentColor : Color.secondary.opacity(0.3))
                }
            }
        }
    }
}
