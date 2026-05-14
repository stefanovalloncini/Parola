import SwiftUI

struct OnboardingScreen<Hero: View, Footer: View>: View {
    let headline: LocalizedStringKey
    let bodyLines: [LocalizedStringKey]
    let primaryTitle: LocalizedStringKey
    let primaryAction: () -> Void
    let secondaryTitle: LocalizedStringKey?
    let secondaryAction: (() -> Void)?
    @ViewBuilder let hero: () -> Hero
    @ViewBuilder let footer: () -> Footer

    init(
        headline: LocalizedStringKey,
        body: [LocalizedStringKey],
        primaryTitle: LocalizedStringKey,
        primaryAction: @escaping () -> Void,
        secondaryTitle: LocalizedStringKey? = nil,
        secondaryAction: (() -> Void)? = nil,
        @ViewBuilder hero: @escaping () -> Hero,
        @ViewBuilder footer: @escaping () -> Footer = { EmptyView() }
    ) {
        self.headline = headline
        self.bodyLines = body
        self.primaryTitle = primaryTitle
        self.primaryAction = primaryAction
        self.secondaryTitle = secondaryTitle
        self.secondaryAction = secondaryAction
        self.hero = hero
        self.footer = footer
    }

    var body: some View {
        GeometryReader { proxy in
            VStack(spacing: 0) {
                Spacer(minLength: 60)

                hero()
                    .frame(maxWidth: 480)
                    .frame(height: heroHeight(for: proxy.size.height))
                    .padding(.horizontal, 24)

                Spacer(minLength: 24)

                VStack(alignment: .leading, spacing: 16) {
                    Text(headline)
                        .font(.system(.largeTitle, design: .default, weight: .bold))
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)

                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(bodyLines.indices, id: \.self) { i in
                            Text(bodyLines[i])
                                .font(.body)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.leading)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    footer()
                        .padding(.top, 4)
                }
                .frame(maxWidth: 540, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.horizontal, 28)

                Spacer(minLength: 24)

                ctaStack
                    .padding(.horizontal, 24)
                    .padding(.bottom, 28)
            }
            .frame(maxWidth: .infinity)
        }
    }

    private var ctaStack: some View {
        VStack(spacing: 12) {
            Button(action: primaryAction) {
                Text(primaryTitle)
                    .font(.body.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .frame(maxWidth: 540)

            if let secondaryTitle, let secondaryAction {
                Button(action: secondaryAction) {
                    Text(secondaryTitle)
                        .font(.body.weight(.medium))
                        .foregroundStyle(.secondary)
                        .frame(height: 32)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func heroHeight(for total: CGFloat) -> CGFloat {
        let target = total * 0.32
        return min(max(target, 200), 320)
    }
}
