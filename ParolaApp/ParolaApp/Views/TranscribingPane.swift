import SwiftUI

struct TranscribingPane: View {
    let file: URL
    let partial: String

    private static let tailID = "transcribing.tail"
    private var hasText: Bool { !partial.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.regular) {
            header
            transcriptBox
        }
        .padding(DS.Spacing.large)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var header: some View {
        HStack(spacing: DS.Spacing.small) {
            ProgressView()
                .progressViewStyle(.circular)
                .controlSize(.small)
                .tint(DS.Color.accent)
            Text("Transcribing \(file.lastPathComponent)…")
                .font(DS.Font.heading)
                .foregroundStyle(DS.Color.primaryText)
            Spacer()
        }
    }

    private var transcriptBox: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: DS.Spacing.regular) {
                    if hasText {
                        Text(partial)
                            .font(DS.Font.transcript)
                            .foregroundStyle(DS.Color.primaryText)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                            .transition(.opacity)
                    }
                    SkeletonLines(count: hasText ? 3 : 6)
                        .id(Self.tailID)
                }
                .padding(DS.Spacing.large)
                .animation(.easeOut(duration: 0.28), value: partial)
            }
            .scrollBounceBehavior(.basedOnSize)
            .onChange(of: partial) { _, _ in
                withAnimation(.easeOut(duration: 0.3)) {
                    proxy.scrollTo(Self.tailID, anchor: .bottom)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .cardBackground(radius: DS.Radius.large)
    }
}
