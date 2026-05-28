import SwiftUI

struct SkeletonLines: View {
    var count: Int = 4

    private static let lines = [
        "Lorem ipsum dolor sit amet consectetur adipiscing",
        "elit sed do eiusmod tempor incididunt ut",
        "labore et dolore magna aliqua ut enim",
        "ad minim veniam quis nostrud exercitation",
        "ullamco laboris nisi ut aliquip ex ea commodo",
        "consequat duis aute irure dolor in reprehenderit",
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.small) {
            ForEach(0..<count, id: \.self) { index in
                Text(Self.lines[index % Self.lines.count])
                    .font(DS.Font.transcript)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .redacted(reason: .placeholder)
        .shimmering()
        .accessibilityHidden(true)
    }
}

private struct Shimmer: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @State private var travel: CGFloat = -1

    func body(content: Content) -> some View {
        content.overlay {
            if !reduceMotion {
                GeometryReader { geometry in
                    LinearGradient(
                        stops: [
                            .init(color: .clear, location: 0),
                            .init(color: highlight, location: 0.5),
                            .init(color: .clear, location: 1),
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: geometry.size.width * 0.5)
                    .offset(x: travel * geometry.size.width * 1.5)
                }
                .mask(content)
                .allowsHitTesting(false)
            }
        }
        .task {
            guard !reduceMotion else { return }
            withAnimation(.linear(duration: 1.25).repeatForever(autoreverses: false)) {
                travel = 1
            }
        }
    }

    private var highlight: Color {
        colorScheme == .dark ? .white.opacity(0.22) : .black.opacity(0.07)
    }
}

extension View {
    func shimmering() -> some View { modifier(Shimmer()) }
}
