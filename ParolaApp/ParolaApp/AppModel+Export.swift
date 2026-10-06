import AppKit
import Foundation
import ParolaCore

extension AppModel {
    // MARK: - Export

    func openExportSheet() {
        guard transcript != nil else { return }
        // The sheet reopens where it was left this session; the first opening starts from the top preset.
        if !hasChosenExportSpec {
            setExportSpec(exportPresets.first?.spec ?? .standard(for: .txt))
        }
        exportSheetOpen = true
    }

    /// A row's Export…: the entry opens in the main window with the export sheet over it.
    func exportEntryFromLibrary(_ id: LibraryEntry.ID) {
        let opening = loadEntry(id)
        Task { [weak self] in
            guard (try? await opening.value) != nil, let self, selectedEntryID == id else { return }
            openExportSheet()
        }
    }

    func closeExportSheet() {
        exportSheetOpen = false
    }

    /// The one way the sheet's spec changes: the style follows the format and the options the format
    /// cannot honour are dropped, so the preview and the file never disagree.
    func setExportSpec(_ spec: ExportSpec) {
        exportSheetSpec = spec.changing(format: spec.format)
        hasChosenExportSpec = true
    }

    func exportFromSheet() {
        exportSheetOpen = false
        pendingExport = exportSheetSpec
    }

    func exportWithPreset(_ id: UUID) {
        guard transcript != nil, let preset = exportPreset(id: id) else { return }
        pendingExport = preset.spec
    }

    func saveExportSheetSpecAsPreset(name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        addExportPreset(name: trimmed, spec: exportSheetSpec)
    }

    /// The pasteboard is a parameter, not `.general` reached for inside: a test that wants to read
    /// back what was copied must not have to take the user's clipboard to do it.
    func copyExportToPasteboard(pasteboard: NSPasteboard) {
        guard let transcript else { return }
        // docx and pdf have no text to paste; the clipboard gets what the preview shows.
        let spec = exportSheetSpec.textRendering
        Task { [weak self] in
            guard let self else { return }
            do {
                let text = try await AppModel.offMainIO { try Exporters.exporter(for: spec).renderText(transcript) }
                pasteboard.clearContents()
                pasteboard.setString(text, forType: .string)
            } catch {
                ParolaLog.error(.export, "copy failed as \(spec.format)", [.error: .error(error)])
                self.exportNotice = .failed(error)
            }
        }
    }

    /// Writes the transcript to `url` as the spec describes it. The bridge and the save panel share this.
    func exportTranscript(spec: ExportSpec, to url: URL) async throws {
        guard let transcript else { throw ParolaError.ioError("No transcript to export.") }
        try await AppModel.offMainIO {
            let data = try Exporters.exporter(for: spec).render(transcript)
            try data.write(to: url, options: .atomic)
            OutputMarker.mark(url)
        }
    }

    func exportSegmentNotesAsMarkdown() {
        guard let transcript,
              let entryID = selectedEntryID,
              let entry = libraryEntry(id: entryID) else {
            return
        }
        let notes = entry.segmentNotes
        // The heading is read, the file name is written: only the latter has characters to lose.
        let title = LibraryEntryDisplay.listTitle(for: entry, showsAITitle: showAITitles)
        let fileName = TranscriptShareFile.safeName(for: title)
        Task { [weak self] in
            guard let self else { return }
            guard let url = await self.filePicker.chooseSaveDestination(
                suggestedName: "\(fileName)-notes.md",
                allowedTypes: [.plainText]
            ) else { return }
            let body = NotesMarkdownRenderer.render(transcript: transcript, notes: notes, title: title)
            do {
                try await AppModel.offMainIO {
                    try Data(body.utf8).write(to: url, options: .atomic)
                    OutputMarker.mark(url)
                }
            } catch {
                ParolaLog.error(.export, "notes export failed", [.error: .error(error)])
                self.exportNotice = .failed(error)
            }
        }
    }

    func dismissExportNotice() {
        exportNotice = nil
    }

    /// Keeps what a newer notice went over, to come back once the strip is clear: one that waits to be dismissed, about something other than `takeID`, the newer one's take.
    func keepCovered(_ covered: ExportNotice?, take takeID: Int?) {
        guard let covered, covered.id != exportNotice?.id, !covered.autoDismisses else { return }
        // One that lasts only while a take runs comes back only for the take it names, and only while that take still runs.
        guard !covered.whileTakeRuns || (covered.takeID != nil && covered.takeID == recording?.takeID && takeIsRunning) else { return }
        guard takeID == nil || covered.takeID != takeID else { return }
        coveredNotice = covered
    }

    /// A notice's button: the notice goes first, then its action runs.
    func performNoticeAction(_ action: ExportNotice.Action) {
        dismissExportNotice()
        switch action.handler {
        case .openEntry(let id):
            openEntryFromLibrary(id, inNewWindow: false)
        case .transcribeEntry(let id):
            Task { [weak self] in
                guard let self, (try? await self.openEntry(id)) != nil else { return }
                self.transcribeLoadedEntry()
            }
        case .retryTake(let takeID):
            guard recording?.takeID == takeID else { return }
            retryFailedTake()
        case .showTake(let takeID):
            guard recording?.takeID == takeID else { return }
            showStage()
        case .retrySavedTake(let failure):
            guard !takeIsRunning else {
                noteRunWaitsForTake()
                return
            }
            retryTake(failure)
        case .showSavedTake(let failure):
            Task { [weak self] in
                guard let entry = try? await failure.save?.value else { return }
                self?.openEntryFromLibrary(entry.id, inNewWindow: false)
            }
        case .openRecentlyDeleted:
            openRecentlyDeleted()
        case .revealFile(let file):
            NSWorkspace.shared.activateFileViewerSelecting([file])
        case .retryRun(let retry):
            retryRun(retry)
        }
    }

    /// A failed run's Retry, from its notice: the run starts again on its page, or waits for a take as a file or a link handed over during it does, so the Retry outlives its notice.
    func retryRun(_ retry: RunRetry) {
        switch retry {
        case .file(let url, let translateOverride):
            guard !takeIsRunning else {
                deferredArrivals.append(url)
                noteRunWaitsForTake()
                return
            }
            // As for a file handed over now: a run beside the batch would fight it for the phase.
            guard !batchIsRunning else {
                importBatchFiles([url])
                return
            }
            showRunPage()
            beginFileTranscription(fileURL: url, translateOverride: translateOverride)
        case .link(.transcribe(let link)):
            showLinkRunPage()
            transcribeYouTube(urlString: link)
        case .link(.subtitles(let link)):
            showLinkRunPage()
            fetchYouTubeSubs(urlString: link)
        }
    }

    func jumpToNextSpeaker() {
        guard let transcript, !transcript.segments.isEmpty else { return }
        let segments = transcript.segments
        let startIdx: Int
        if let current = currentSegmentID,
           let idx = segments.firstIndex(where: { $0.id == current }) {
            startIdx = idx
        } else {
            startIdx = -1
        }
        let currentSpeaker = startIdx >= 0 ? segments[startIdx].speaker : nil
        for offset in 1..<segments.count {
            let idx = (startIdx + offset) % segments.count
            if segments[idx].speaker != currentSpeaker, segments[idx].speaker != nil {
                seek(to: segments[idx])
                return
            }
        }
    }

    /// A take still playing from its working file goes by its own title, never the file's name.
    var transcriptHeaderTitle: String {
        recordedTakeTitle(playing: sourceFileURL) ?? Self.transcriptDisplayTitle(
            sourceFileURL: sourceFileURL,
            entry: selectedEntryID.flatMap { libraryEntry(id: $0) },
            showsAITitle: showAITitles,
            fallback: String(localized: "Untitled")
        )
    }

    /// The header's name while the main window shows a transcript; nil on any other page.
    var shownTranscriptTitle: String? {
        guard route == .transcript, hasTranscript, !isBrowsingLibrary, case .ready = transcriptRoutePhase else { return nil }
        return transcriptHeaderTitle
    }

    var currentTranscriptTitle: String {
        recordedTakeTitle(playing: sourceFileURL) ?? Self.transcriptDisplayTitle(
            sourceFileURL: sourceFileURL,
            entry: selectedEntryID.flatMap { libraryEntry(id: $0) },
            showsAITitle: showAITitles,
            fallback: String(localized: "Transcript")
        )
    }

    func shareTranscriptViaMail() {
        guard let transcript else { return }
        let title = currentTranscriptTitle
        guard let url = TranscriptMail.mailtoURL(title: title, transcript: transcript) else { return }
        NSWorkspace.shared.open(url)
    }

    func shareTranscriptAsTextFile() {
        guard let transcript,
              let fileURL = try? TranscriptShareFile.write(title: currentTranscriptTitle, text: transcript.text),
              let anchorView = NSApp.keyWindow?.contentView
        else { return }
        let picker = NSSharingServicePicker(items: [fileURL])
        let anchor = NSRect(x: anchorView.bounds.midX, y: anchorView.bounds.maxY - 1, width: 1, height: 1)
        picker.show(relativeTo: anchor, of: anchorView, preferredEdge: .minY)
    }

    /// Copy Transcript's text: paragraphs, with speaker names once two or more speak; a long one is built off the main actor.
    func copyTranscriptAsPlainText(_ transcript: Transcript, to pasteboard: NSPasteboard = .general) async {
        let segments = transcript.segments
        let labelled = transcript.uniqueSpeakers.count >= 2
        let text: String
        if segments.count > TranscriptDerive.synchronousCap {
            text = await Task.detached(priority: .userInitiated) {
                TranscriptParagraphs.plainText(segments: segments, includeSpeakerLabels: labelled)
            }.value
        } else {
            text = TranscriptParagraphs.plainText(segments: segments, includeSpeakerLabels: labelled)
        }
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    func copyTranscript(to pasteboard: NSPasteboard = .general) async {
        guard let transcript else { return }
        await copyTranscriptAsPlainText(transcript, to: pasteboard)
    }

    func copyTranscriptToPasteboard(withTimestamps: Bool, favoritesOnly: Bool = false, pasteboard: NSPasteboard) {
        guard let transcript else { return }
        let favorites = favoriteSegmentIDs
        Task {
            guard let text = try? await AppModel.offMainIO({
                var source = transcript
                if favoritesOnly {
                    source.segments = source.segments.filter { favorites.contains($0.id) }
                }
                return withTimestamps ? TranscriptTimestampedText.render(source) : source.text
            }) else { return }
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
        }
    }

    func copyTranscriptAsFormat(_ format: ExportFormat) {
        guard let transcript else { return }
        let exporter = makeExporter(for: format)
        Task {
            guard let data = try? await AppModel.offMainIO({ try exporter.render(transcript) }),
                  let text = String(data: data, encoding: .utf8) else {
                return
            }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
    }

    func printTranscript() {
        guard let transcript else { return }
        let title = currentTranscriptTitle
        let attributed = Self.makePrintableAttributedString(for: transcript, title: title)

        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 612, height: 792))
        textView.isEditable = false
        textView.textContainerInset = NSSize(width: 36, height: 48)
        textView.textStorage?.setAttributedString(attributed)

        let printInfo = NSPrintInfo.shared
        printInfo.horizontalPagination = .fit
        printInfo.verticalPagination = .automatic
        printInfo.topMargin = 36
        printInfo.bottomMargin = 36
        printInfo.leftMargin = 36
        printInfo.rightMargin = 36

        let operation = NSPrintOperation(view: textView, printInfo: printInfo)
        operation.showsPrintPanel = true
        operation.showsProgressPanel = true
        operation.jobTitle = title
        operation.run()
    }

    private static func makePrintableAttributedString(for transcript: Transcript, title: String) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let titleAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.boldSystemFont(ofSize: 18),
            .foregroundColor: NSColor.labelColor,
        ]
        result.append(NSAttributedString(string: title + "\n\n", attributes: titleAttrs))

        let stampAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        let bodyAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12),
            .foregroundColor: NSColor.labelColor,
        ]
        let speakerAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: NSColor.labelColor,
        ]

        for segment in transcript.segments {
            result.append(NSAttributedString(string: Timecode.format(segment.start) + "  ", attributes: stampAttrs))
            if let speaker = segment.speaker {
                result.append(NSAttributedString(string: speaker + ": ", attributes: speakerAttrs))
            }
            result.append(NSAttributedString(string: segment.text.trimmingCharacters(in: .whitespaces) + "\n\n", attributes: bodyAttrs))
        }
        return result
    }

    func performExport(_ spec: ExportSpec) {
        guard transcript != nil else { return }
        Task { [weak self] in
            guard let self else { return }
            let name = TranscriptShareFile.safeName(for: self.currentTranscriptTitle)
            guard let url = await self.filePicker.chooseSaveDestination(
                suggestedName: "\(name).\(spec.format.fileExtension)",
                // Unconstrained: most export formats (docx, pdf, csv, srt, ...) don't conform to
                // .plainText, and a constrained panel rewrites their extension to .txt.
                allowedTypes: []
            ) else { return }
            do {
                try await self.exportTranscript(spec: spec, to: url)
            } catch {
                ParolaLog.error(.export, "export failed as \(spec.format)", [.error: .error(error)])
                self.exportNotice = .failed(error)
            }
        }
    }

    var subtitleCaptionLength: CaptionLength {
        CaptionLength(rawValue: subtitleCaptionLengthRaw) ?? .none
    }

    /// The spec the saved export settings describe for a format.
    func exportSpec(for format: ExportFormat, includeTimestamps: Bool? = nil) -> ExportSpec {
        var spec = ExportSpec.standard(for: format)
        switch format {
        case .txt:
            spec.options.timestamps = includeTimestamps ?? txtExportTimestamps
        case .md:
            spec.options.timestamps = includeTimestamps ?? markdownTimestamps
        case .html:
            spec.options.timestamps = includeTimestamps ?? spec.options.timestamps
            spec.options.htmlTheme = HtmlExportTheme(rawValue: htmlExportThemeRaw) ?? .light
        case .srt, .vtt:
            spec.options.captionLength = subtitleCaptionLength
        default:
            break
        }
        return spec
    }

    func makeExporter(for format: ExportFormat, includeTimestamps: Bool? = nil) -> TranscriptExporter {
        Exporters.exporter(for: exportSpec(for: format, includeTimestamps: includeTimestamps))
    }
}
