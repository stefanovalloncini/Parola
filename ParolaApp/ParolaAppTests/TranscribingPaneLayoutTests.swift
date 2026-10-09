import AppKit
import SwiftUI
import Testing
@testable import Parola

/// What a view answered to each size it was asked about, in order.
@MainActor
private final class Answers {
    var sizes: [CGSize] = []
}

/// What its child was measured with.
@MainActor
private final class Measures {
    var asked: [ProposedViewSize] = []
    /// Those that came of the size checks alone, not of laying the box out.
    var duringChecks: [ProposedViewSize] = []
}

/// Asks its one child about each proposal in turn, the way a window's size checks do, and keeps the answers.
private struct Asking: Layout {
    let proposals: [ProposedViewSize]
    let answers: Answers
    var measures: Measures?

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        MainActor.assumeIsolated {
            let before = measures?.asked.count ?? 0
            answers.sizes = proposals.map { subviews[0].sizeThatFits($0) }
            if let measures { measures.duringChecks += measures.asked[before...] }
        }
        return proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews[0].place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
    }
}

private struct Counting: Layout {
    let measures: Measures

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        MainActor.assumeIsolated { measures.asked.append(proposal) }
        return subviews[0].sizeThatFits(proposal)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews[0].place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
    }
}

@MainActor
@Suite("The file pane's transcript box", .serialized)
struct TranscribingPaneLayoutTests {
    private static let words = String(repeating: "the meeting opened with a quick agenda review before the numbers ", count: 30)

    /// The checks a window makes of a pane: its narrowest, a height of nothing to find its minimum, and the open-ended ones.
    private static let proposals: [ProposedViewSize] = [
        ProposedViewSize(width: MainWindowLayout.narrowestPaneWidth, height: 0), ProposedViewSize(width: 680, height: 0),
        .infinity, .unspecified,
        ProposedViewSize(width: 920, height: 600), ProposedViewSize(width: 300, height: 40),
        ProposedViewSize(width: 640, height: nil), ProposedViewSize(width: nil, height: 400),
    ]

    /// The pane's scroll box with its frame, with or without `OfferedSize` around the scroll view.
    @ViewBuilder
    private static func box(offered: Bool, measures: Measures = Measures()) -> some View {
        let scroll = ScrollView {
            VStack(alignment: .leading, spacing: DS.Spacing.regular) {
                Text(words)
                    .font(DS.Font.transcript)
                    .lineSpacing(DS.Spacing.transcriptLeading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(DS.Spacing.large)
        }
        Group {
            if offered {
                OfferedSize { Counting(measures: measures) { scroll } }
            } else {
                scroll
            }
        }
        .frame(maxWidth: .infinity, minHeight: DS.Size.liveTranscriptMinHeight, maxHeight: 300)
    }

    private func answers(offered: Bool) -> [CGSize] {
        let answers = Answers()
        let hosted = HostedWindow(Asking(proposals: Self.proposals, answers: answers) { Self.box(offered: offered) }, width: 1180, height: 760)
        defer { hosted.close() }
        return answers.sizes
    }

    @Test("the box answers every size check as it did before, offered size or not")
    func answersAsBefore() throws {
        let before = answers(offered: false)
        let after = answers(offered: true)
        try #require(before.count == Self.proposals.count)
        #expect(after == before)
    }

    @Test("a check with both sides given never measures the transcript; one that leaves a side open still does")
    func givenSizesSkipTheText() {
        let measures = Measures()
        let given: [ProposedViewSize] = [.zero, .infinity, ProposedViewSize(width: 920, height: 600)]
        let hosted = HostedWindow(
            Asking(proposals: given, answers: Answers(), measures: measures) { Self.box(offered: true, measures: measures) },
            width: 1180, height: 760
        )
        defer { hosted.close() }
        #expect(!measures.asked.isEmpty, "laying the box out still measures it")
        #expect(measures.duringChecks.isEmpty, "the size checks measured the transcript for \(measures.duringChecks)")

        let openMeasures = Measures()
        let open = HostedWindow(
            Asking(proposals: [.unspecified], answers: Answers(), measures: openMeasures) {
                Self.box(offered: true, measures: openMeasures)
            },
            width: 1180, height: 760
        )
        defer { open.close() }
        #expect(!openMeasures.duringChecks.isEmpty)
    }
}
