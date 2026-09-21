import SwiftUI
import ParolaCore

/// The window's flowing-text mode. It builds the same chunks the main pane does, with the same
/// speaker colours and favorite stars, and answers a click on a run by seeking this window's player.
struct EntryViewerContinuous: View {
    let session: EntryWindowSession
    let onEditAttempt: () -> Void

    @Environment(AppModel.self) private var model
    @State private var chunks: [ContinuousChunks.Chunk] = []
    @State private var chunkIndexBySegment: [TranscriptSegment.ID: Int] = [:]
    @State private var highlightedSegmentID: TranscriptSegment.ID?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                HStack(spacing: 0) {
                    Spacer(minLength: 0)
                    LazyVStack(alignment: .leading, spacing: DS.Spacing.regular) {
                        ForEach(chunks) { chunk in
                            chunkRow(chunk).id(chunk.id)
                        }
                    }
                    .frame(maxWidth: 720, alignment: .leading)
                    .padding(.horizontal, DS.Spacing.large)
                    .padding(.vertical, DS.Spacing.large)
                    Spacer(minLength: 0)
                }
            }
            .tint(.primary)
            .environment(\.openURL, OpenURLAction { url in
                // The assign links the shared builder writes belong to the main window; swallow them here.
                if url.scheme == "parola-assign" { return .handled }
                guard url.scheme == "parola-seek", let id = url.host.flatMap(Int.init) else {
                    return .systemAction
                }
                session.seek(toSegment: id)
                return .handled
            })
            .onAppear { rebuild() }
            .onChange(of: buildKey) { _, _ in rebuild() }
            .onChange(of: session.currentSegmentID) { _, id in
                applyHighlight()
                guard let id, let chunkID = chunkIndexBySegment[id] else { return }
                withAnimation(.easeInOut(duration: 0.2)) { proxy.scrollTo(chunkID, anchor: .center) }
            }
        }
    }

    private func chunkRow(_ chunk: ContinuousChunks.Chunk) -> some View {
        Group {
            if let translation = chunk.translation, model.translationSideBySide {
                HStack(alignment: .top, spacing: DS.Spacing.regular) {
                    chunkText(chunk.text)
                    chunkText(translation)
                }
            } else {
                VStack(alignment: .leading, spacing: DS.Spacing.small) {
                    chunkText(chunk.text)
                    if let translation = chunk.translation { chunkText(translation) }
                }
            }
        }
        .simultaneousGesture(TapGesture(count: 2).onEnded { onEditAttempt() })
    }

    private func chunkText(_ text: AttributedString) -> some View {
        Text(text)
            .font(model.transcriptCompact ? DS.Font.transcriptCompact : DS.Font.transcript)
            .lineSpacing(model.transcriptCompact ? 3 : 5)
            .textSelection(.enabled)
            // Definite height; without it the layout pass re-typesets the chunk Text in a loop on long audio.
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private struct BuildKey: Equatable {
        let segmentCount: Int
        let favorites: Set<Int>
        let colors: [String: Int]
        let translations: Int
        let loaded: Bool
    }

    private var buildKey: BuildKey {
        BuildKey(
            segmentCount: session.transcript?.segments.count ?? 0,
            favorites: session.favorites,
            colors: session.speakerColorIndices,
            translations: session.translations.count,
            loaded: session.transcript != nil
        )
    }

    private func rebuild() {
        guard let transcript = session.transcript else {
            chunks = []
            chunkIndexBySegment = [:]
            highlightedSegmentID = nil
            return
        }
        let useSpeakerColor = session.speakers.count >= 2
        let built = ContinuousChunks.build(
            segments: transcript.segments,
            useSpeakerColor: useSpeakerColor,
            speakerColorIndices: useSpeakerColor ? session.speakerColorIndices : [:],
            primaryText: DS.Color.primaryText,
            favoriteColor: DS.Color.accent,
            favorites: session.favorites,
            translations: session.translations,
            translationColor: DS.Color.secondaryText
        )
        chunks = built
        chunkIndexBySegment = ContinuousChunks.chunkIndexBySegment(for: built)
        highlightedSegmentID = nil
        applyHighlight()
    }

    private func applyHighlight() {
        let next = session.currentSegmentID
        guard next != highlightedSegmentID else { return }
        ContinuousChunks.moveHighlight(
            in: &chunks,
            chunkIndexBySegment: chunkIndexBySegment,
            from: highlightedSegmentID,
            to: next,
            highlightColor: DS.Color.highlight
        )
        highlightedSegmentID = next
    }
}
