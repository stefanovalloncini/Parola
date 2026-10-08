import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Parola
import ParolaCore
import ParolaTestSupport

/// ⎋ is the footer's Cancel or Close, ↩ its default button, and a sheet with no Cancel still closes on ⎋.
@MainActor
@Suite("Sheet keys", .serialized)
struct SheetKeysTests {
    private final class Calls {
        var cancelled = 0
        var saved = 0
    }

    private func makeModel(_ label: String) -> AppModel {
        AppModel(skipBootstrap: true, defaults: temporaryDefaults(), libraryURL: makeTempLibraryURL(label))
    }

    private func host(_ view: some View, model: AppModel, width: CGFloat = 480, height: CGFloat = 640) -> HostedWindow {
        HostedWindow(view.environment(model), width: width, height: height)
    }

    @Test("⎋ closes Manage People, whose footer has only Done")
    func managePeopleEscapes() {
        let hosted = host(ManagePeopleSheet(), model: makeModel("sheet-keys-people"), width: 460, height: 400)
        defer { hosted.close() }
        let hostedEscape = hosted.press(.escape)
        #expect(hostedEscape)
        let hostedDismissed = !hosted.window.isVisible
        #expect(hostedDismissed)
    }

    @Test("⎋ closes a prompt's output, and its failure, whose only button is Close")
    func promptOutputEscapes() {
        let model = makeModel("sheet-keys-prompt")
        let shown = host(PromptOutputSheet(output: .init(promptName: "Bullet points", text: "- One")), model: model)
        let shownEscape = shown.press(.escape)
        #expect(shownEscape)
        let shownDismissed = !shown.window.isVisible
        #expect(shownDismissed)
        shown.close()
        let failed = host(PromptOutputSheet(output: .init(promptName: "Bullet points", text: "", failure: "No model")), model: model)
        defer { failed.close() }
        let failedEscape = failed.press(.escape)
        #expect(failedEscape)
        let failedDismissed = !failed.window.isVisible
        #expect(failedDismissed)
    }

    @Test("⎋ closes the export sheet")
    func exportEscapes() {
        let model = makeModel("sheet-keys-export")
        model.transcript = Transcript(
            segments: [TranscriptSegment(id: 0, start: 0, end: 1, text: "Hello.")],
            language: "en",
            modelName: "stub"
        )
        model.openExportSheet()
        let hosted = host(ExportSheet(), model: model, width: 760, height: 620)
        defer { hosted.close() }
        #expect(model.exportSheetOpen)
        let hostedEscape = hosted.press(.escape)
        #expect(hostedEscape)
        #expect(!model.exportSheetOpen)
    }

    @Test("the AI service editor: ⎋ cancels and ↩ saves")
    func aiServiceEditorKeys() {
        let calls = Calls()
        let service = AIServiceConfig(kind: .openAI, name: "Work OpenAI", endpoint: nil, model: "gpt-4o-mini")
        let editor = AIServiceEditor(
            draft: AIServiceDraft(service: service, isNew: false),
            onSave: { _, _ in calls.saved += 1 },
            onCancel: { calls.cancelled += 1 }
        )
        let hosted = host(editor, model: makeModel("sheet-keys-ai"), width: 560, height: 620)
        defer { hosted.close() }
        let hostedEscape = hosted.press(.escape)
        #expect(hostedEscape)
        #expect(calls.cancelled == 1)
        let hostedReturn = hosted.press(.return)
        #expect(hostedReturn)
        #expect(calls.saved == 1)
    }

    @Test("the Obsidian destination editor: ⎋ cancels and ↩ saves")
    func obsidianEditorKeys() {
        let calls = Calls()
        let destination = ObsidianVaultFolderDestination(name: "Vault", vaultBookmark: Data([0x01]), vaultPath: "/tmp/vault")
        let editor = ObsidianDestinationEditor(
            destination: destination,
            isNew: false,
            onSave: { _ in calls.saved += 1 },
            onCancel: { calls.cancelled += 1 }
        )
        let hosted = host(editor, model: makeModel("sheet-keys-obsidian"), width: 560, height: 720)
        defer { hosted.close() }
        let hostedEscape = hosted.press(.escape)
        #expect(hostedEscape)
        #expect(calls.cancelled == 1)
        let hostedReturn = hosted.press(.return)
        #expect(hostedReturn)
        #expect(calls.saved == 1)
    }

    @Test("Transcripts leave this Mac: ⎋ cancels and ↩ is I understand")
    func remoteAIKeys() {
        let calls = Calls()
        let notice = RemoteAIAcknowledgementSheet(
            serviceName: "OpenAI",
            onAccept: { calls.saved += 1 },
            onCancel: { calls.cancelled += 1 }
        )
        let hosted = host(notice, model: makeModel("sheet-keys-remote"), width: 460, height: 300)
        defer { hosted.close() }
        let hostedEscape = hosted.press(.escape)
        #expect(hostedEscape)
        #expect(calls.cancelled == 1)
        let hostedReturn = hosted.press(.return)
        #expect(hostedReturn)
        #expect(calls.saved == 1)
    }

    @Test("⎋ closes Burn, Speakers, Transcribe Link and Segment note through their Cancel")
    func cancelSheetsEscape() {
        let model = makeModel("sheet-keys-cancel")
        let segment = TranscriptSegment(id: 0, start: 0, end: 1, text: "Hello.", speaker: "Ada")
        let transcript = Transcript(segments: [segment], language: "en", modelName: "stub")
        model.transcript = transcript
        model.ytDlpLocator = { "/opt/homebrew/bin/yt-dlp" }
        let burn = host(BurnStyleSheet(), model: model)
        let burnEscape = burn.press(.escape)
        #expect(burnEscape, "Burn")
        let burnDismissed = !burn.window.isVisible
        #expect(burnDismissed, "Burn")
        burn.close()
        let speakers = host(SpeakersSheet(transcript: transcript), model: model)
        let speakersEscape = speakers.press(.escape)
        #expect(speakersEscape, "Speakers")
        let speakersDismissed = !speakers.window.isVisible
        #expect(speakersDismissed, "Speakers")
        speakers.close()
        let link = host(YouTubeURLSheet(), model: model)
        let linkEscape = link.press(.escape)
        #expect(linkEscape, "Transcribe Link")
        let linkDismissed = !link.window.isVisible
        #expect(linkDismissed, "Transcribe Link")
        link.close()
        let note = host(SegmentNoteSheet(target: SegmentNoteTarget(entryID: "entry", segment: segment, note: nil)), model: model)
        defer { note.close() }
        let noteEscape = note.press(.escape)
        #expect(noteEscape, "Segment note")
        let noteDismissed = !note.window.isVisible
        #expect(noteDismissed, "Segment note")
    }
}
