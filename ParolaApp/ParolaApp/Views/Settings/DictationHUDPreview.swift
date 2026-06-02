import SwiftUI
import ParolaCore

struct DictationHUDPreview: View {
    let style: DictationIndicatorStyle
    let modeName: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Preview")
                .font(DS.Font.subheadlineEmphasized)
                .foregroundStyle(.secondary)
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.primary.opacity(0.04))
                    .frame(height: 92)
                hudMock
            }
        }
    }

    @ViewBuilder
    private var hudMock: some View {
        switch style {
        case .overlay: overlayMock
        case .notch:   notchMock
        case .minimal: minimalMock
        }
    }

    private var overlayMock: some View {
        HStack(spacing: 10) {
            bars
            Text("Listening")
                .font(DS.Font.calloutEmphasized)
                .foregroundStyle(.white)
            if let modeName {
                Text(modeName)
                    .font(DS.Font.caption2Emphasized)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(.white.opacity(0.18)))
            }
            Spacer(minLength: 0)
            Text("00:03")
                .font(DS.Font.caption2Mono)
                .foregroundStyle(.white.opacity(0.7))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Capsule().fill(.black.opacity(0.85)))
        .frame(width: 220)
    }

    private var notchMock: some View {
        HStack(spacing: 6) {
            bars
            Text("Listening")
                .font(DS.Font.caption2Medium)
                .foregroundStyle(.white)
            Spacer(minLength: 0)
            Text("00:03")
                .font(DS.Font.caption2Mono)
                .foregroundStyle(.white.opacity(0.6))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.black.opacity(0.9)))
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
