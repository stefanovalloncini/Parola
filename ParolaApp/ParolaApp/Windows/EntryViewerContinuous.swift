import SwiftUI
import ParolaCore

/// The window's flowing-text mode: the same chunks the main pane builds, seeking this window's player.
struct EntryViewerContinuous: View {
    let session: EntryWindowSession
    let onEditAttempt: () -> Void

    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var chunks: [ContinuousChunks.Chunk] = []
    @State private var chunkIndexBySegment: [TranscriptSegment.ID: Int] = [:]
    @State private var highlightedSegmentID: TranscriptSegment.ID?
    @State private var buildTask: Task<Void, Never>?
    @State private var appliedSignature: Int?

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
            .onChange(of: session.contentSignature) { _, _ in rebuild() }
            // The chunks cache resolved colours, so a theme change has to rebuild them.
            .onChange(of: model.themeRevision) { _, _ in rebuild(force: true) }
            .onDisappear { buildTask?.cancel() }
            .onChange(of: session.currentSegmentID) { _, id in
                applyHighlight()
                guard let id, let chunkID = chunkIndexBySegment[id] else { return }
                withAnimation(DS.Motion.follow(reduceMotion: reduceMotion)) { proxy.scrollTo(chunkID, anchor: .center) }
            }
        }
    }

    private func chunkRow(_ chunk: ContinuousChunks.Chunk) -> some View {
        let text = searched(chunk)
        return Group {
            if let translation = chunk.translation, model.translationSideBySide {
                HStack(alignment: .top, spacing: DS.Spacing.regular) {
                    chunkText(text)
                    chunkText(translation)
                }
            } else {
                VStack(alignment: .leading, spacing: DS.Spacing.small) {
                    chunkText(text)
                    if let translation = chunk.translation { chunkText(translation) }
                }
            }
        }
        .simultaneousGesture(TapGesture(count: 2).onEnded { onEditAttempt() })
    }

    private func searched(_ chunk: ContinuousChunks.Chunk) -> AttributedString {
        guard !session.matches.isEmpty else { return chunk.text }
        return ContinuousChunks.searched(chunk, matches: session.matches(in:), currentMatchID: session.currentMatch?.id)
    }

    private func chunkText(_ text: AttributedString) -> some View {
        Text(text)
            .font(model.transcriptCompact ? DS.Font.transcriptCompact : DS.Font.transcript)
            .lineSpacing(model.transcriptCompact ? DS.Spacing.transcriptLeadingCompact : DS.Spacing.transcriptLeading)
            .textSelection(.enabled)
            // Definite height; without it the layout pass re-typesets the chunk Text in a loop on long audio.
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func rebuild(force: Bool = false) {
        buildTask?.cancel()
        guard let transcript = session.transcript else {
            chunks = []
            chunkIndexBySegment = [:]
            highlightedSegmentID = nil
            appliedSignature = nil
            return
        }
        let signature = session.contentSignature
        guard force || signature != appliedSignature else { return }
        let useSpeakerColor = session.speakers.count >= 2
        let segments = transcript.segments
        let colors = useSpeakerColor ? session.speakerColorIndices : [:]
        let favorites = session.favorites
        let translations = session.translations
        // DS's resolved palette is main-actor storage; read it here so the detached build never touches it.
        let primaryText = DS.Color.primaryText
        let accent = DS.Color.accent
        let secondaryText = DS.Color.secondaryText
        if segments.count <= ContinuousChunks.synchronousBuildCap {
            apply(
                ContinuousChunks.build(
                    segments: segments, useSpeakerColor: useSpeakerColor, speakerColorIndices: colors,
                    primaryText: primaryText, favoriteColor: accent, favorites: favorites,
                    translations: translations, translationColor: secondaryText
                ),
                signature: signature
            )
        } else {
            buildTask = Task {
                await ContinuousChunks.buildOffMain(
                    segments: segments,
                    useSpeakerColor: useSpeakerColor,
                    speakerColorIndices: colors,
                    primaryText: primaryText,
                    favoriteColor: accent,
                    favorites: favorites,
                    translations: translations,
                    translationColor: secondaryText,
                    signature: signature,
                    apply: apply
                )
            }
        }
    }

    private func apply(_ built: [ContinuousChunks.Chunk], signature: Int) {
        chunks = built
        chunkIndexBySegment = ContinuousChunks.chunkIndexBySegment(for: built)
        highlightedSegmentID = nil
        appliedSignature = signature
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
