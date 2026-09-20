import SwiftUI
import ParolaCore

struct DictationHUDPreview: View {
    let style: DictationIndicatorStyle
    let modeName: String?

    private static let stageRadius: CGFloat = 10
    private static let fieldRadius: CGFloat = 4
    private static let hudRadius: CGFloat = 10
    private static let notchRadius: CGFloat = 12
    private static let hudInset: CGFloat = 10
    private static let hudVerticalInset: CGFloat = 5
    private static let badgeInset: CGFloat = 5
    private static let badgeVerticalInset: CGFloat = 1

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Preview")
                .font(DS.Font.bodyStrong)
                .foregroundStyle(DS.Color.secondaryText)
            ZStack {
                RoundedRectangle(cornerRadius: Self.stageRadius)
                    .fill(Color.primary.opacity(0.04))
                    .frame(height: 92)
                hudMock
            }
        }
    }

    @ViewBuilder
    private var hudMock: some View {
        switch style {
        case .nearField: nearFieldMock
        case .overlay: overlayMock
        case .notch:   notchMock
        case .minimal: minimalMock
        }
    }

    private var nearFieldMock: some View {
        VStack(alignment: .leading, spacing: 6) {
            RoundedRectangle(cornerRadius: Self.fieldRadius)
                .stroke(Color.primary.opacity(0.25), lineWidth: 1)
                .frame(width: 180, height: 22)
                .overlay(alignment: .leading) {
                    Text("Type here…")
                        .font(DS.Font.caption)
                        .foregroundStyle(.tertiary)
                        .padding(.leading, DS.Spacing.snug)
                }
            HStack(spacing: 6) {
                bars
                Text("Listening")
                    .font(DS.Font.caption)
                    .foregroundStyle(.white)
            }
            .padding(.horizontal, Self.hudInset)
            .padding(.vertical, Self.hudVerticalInset)
            .background(RoundedRectangle(cornerRadius: Self.hudRadius, style: .continuous).fill(.black.opacity(0.88)))
        }
    }

    private var overlayMock: some View {
        HStack(spacing: 10) {
            bars
            Text("Listening")
                .font(DS.Font.bodyStrong)
                .foregroundStyle(.white)
            if let modeName {
                Text(modeName)
                    .font(DS.Font.caption)
                    .foregroundStyle(.white)
                    .padding(.horizontal, Self.badgeInset)
                    .padding(.vertical, Self.badgeVerticalInset)
                    .background(Capsule().fill(.white.opacity(0.18)))
            }
            Spacer(minLength: 0)
            Text("00:03")
                .font(DS.Font.mono)
                .foregroundStyle(.white.opacity(0.7))
        }
        .padding(.horizontal, DS.Spacing.regular)
        .padding(.vertical, DS.Spacing.small)
        .background(Capsule().fill(.black.opacity(0.85)))
        .frame(width: 220)
    }

    private var notchMock: some View {
        HStack(spacing: 6) {
            bars
            Text("Listening")
                .font(DS.Font.caption)
                .foregroundStyle(.white)
            Spacer(minLength: 0)
            Text("00:03")
                .font(DS.Font.mono)
                .foregroundStyle(.white.opacity(0.6))
        }
        .padding(.horizontal, Self.hudInset)
        .padding(.vertical, DS.Spacing.tight)
        .background(RoundedRectangle(cornerRadius: Self.notchRadius, style: .continuous).fill(.black.opacity(0.9)))
        .frame(width: 170, height: 24)
    }

    private var minimalMock: some View {
        ZStack {
            Circle().fill(.black.opacity(0.85))
            bars
        }
        .frame(width: 32, height: 32)
    }

    private var bars: some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(0..<5, id: \.self) { idx in
                Capsule()
                    .fill(.white)
                    .frame(width: 2, height: barHeight(at: idx))
            }
        }
    }

    private func barHeight(at index: Int) -> CGFloat {
        let heights: [CGFloat] = [6, 10, 14, 9, 7]
        return heights[index % heights.count]
    }
}
