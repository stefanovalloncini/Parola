import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Parola
import ParolaCore
import ParolaTestSupport

/// Cancel or Close sits right beside the default button at the trailing edge, as on every Mac sheet.
@MainActor
@Suite("Sheet footer order", .serialized)
struct SheetFooterOrderTests {
    private func makeModel(_ label: String) -> AppModel {
        let model = AppModel(skipBootstrap: true, defaults: temporaryDefaults(), libraryURL: makeTempLibraryURL(label))
        model.transcript = Transcript(
            segments: [TranscriptSegment(id: 0, start: 0, end: 1, text: "Hello.", speaker: "Ada")],
            language: "en",
            modelName: "stub"
        )
        model.ytDlpLocator = { "/opt/homebrew/bin/yt-dlp" }
        return model
    }

    private func frames(of leaves: [String], in view: some View, model: AppModel, width: CGFloat = 480) throws -> (frames: [CGRect], edges: CGRect) {
        let hosted = HostedWindow(view.environment(model), width: width, height: 640)
        defer { hosted.close() }
        let elements = HostedAccessibility.elements(in: hosted.host)
        var found: [CGRect] = []
        for leaf in leaves {
            let match = elements.first { $0.identifier?.hasSuffix(leaf) == true }
            found.append(try #require(match, "no \(leaf)").frame)
        }
        return (found, hosted.window.frame)
    }

    private func expectSideBySideAtTheTrailingEdge(_ frames: [CGRect], edges: CGRect, _ sheet: String) {
        for (leading, trailing) in zip(frames, frames.dropFirst()) {
            #expect(leading.maxX <= trailing.minX, "\(sheet): out of order")
            #expect(trailing.minX - leading.maxX < 24, "\(sheet): \(trailing.minX - leading.maxX) pt apart")
        }
        let last = frames.last ?? .zero
        let margin = SheetFrame<EmptyView, EmptyView>.margin
        #expect(abs(edges.maxX - last.maxX - margin) < 0.5, "\(sheet): the default button ends \(edges.maxX - last.maxX) pt in")
    }

    @Test("Burn: Cancel · Choose Video…")
    func burn() throws {
        let model = makeModel("footer-order-burn")
        let found = try frames(of: ["BurnStyle.Button.Cancel", "BurnStyle.Button.ChooseVideo"], in: BurnStyleSheet(), model: model)
        expectSideBySideAtTheTrailingEdge(found.frames, edges: found.edges, "Burn")
    }

    @Test("Speakers: Cancel · Done")
    func speakers() throws {
        let model = makeModel("footer-order-speakers")
        let transcript = try #require(model.transcript)
        let found = try frames(of: ["Speakers.Button.Cancel", "Speakers.Button.Done"], in: SpeakersSheet(transcript: transcript), model: model)
        expectSideBySideAtTheTrailingEdge(found.frames, edges: found.edges, "Speakers")
    }

    @Test("Prompt output: Close · Copy")
    func promptOutput() throws {
        let model = makeModel("footer-order-prompt")
        let sheet = PromptOutputSheet(output: .init(promptName: "Bullet points", text: "- One"))
        let found = try frames(of: ["PromptOutput.Button.Close", "PromptOutput.Button.Copy"], in: sheet, model: model)
        expectSideBySideAtTheTrailingEdge(found.frames, edges: found.edges, "Prompt output")
    }

    @Test("Transcribe Link: Use Captions · Cancel · Transcribe, the alternative before Cancel")
    func link() throws {
        let model = makeModel("footer-order-link")
        let leaves = ["YouTube.Button.UseCaptions", "YouTube.Button.Cancel", "YouTube.Button.Transcribe"]
        let found = try frames(of: leaves, in: YouTubeURLSheet(), model: model)
        expectSideBySideAtTheTrailingEdge(found.frames, edges: found.edges, "Transcribe Link")
    }

    @Test("Transcribe Link's buttons show whole, with or without the yt-dlp note beside them", arguments: [true, false])
    func linkFits(_ installed: Bool) throws {
        let locale = Locale(identifier: "it_IT")
        let model = makeModel("footer-order-link-fit")
        if !installed { model.ytDlpLocator = { nil } }
        let buttons: [(leaf: String, title: LocalizedStringKey, primary: Bool)] = [
            ("YouTube.Button.UseCaptions", "Use Captions", false),
            ("YouTube.Button.Cancel", "Cancel", false),
            ("YouTube.Button.Transcribe", "Transcribe", true),
        ]
        let found = try frames(of: buttons.map(\.leaf), in: YouTubeURLSheet().environment(\.locale, locale), model: model)
        for (button, frame) in zip(buttons, found.frames) {
            let whole = SheetButtonSize.natural(button.title, primary: button.primary, locale: locale)
            #expect(frame.width >= whole.width - 0.5, "\(button.leaf) is \(frame.width) pt of \(whole.width)")
        }
    }

    @Test("the other sheets already end in Cancel · default", arguments: ["it_IT", "en_US"])
    func others(_ identifier: String) throws {
        let locale = Locale(identifier: identifier)
        let model = makeModel("footer-order-others")
        let segment = TranscriptSegment(id: 0, start: 0, end: 1, text: "Hello.", speaker: "Ada")
        let note = SegmentNoteSheet(target: SegmentNoteTarget(entryID: "entry", segment: segment, note: "Call back"))
            .environment(\.locale, locale)
        let noteFrames = try frames(of: ["Button.Delete", "Button.Cancel", "Button.Save"], in: note, model: model, width: 440)
        #expect(noteFrames.frames[0].maxX < noteFrames.frames[1].minX - 24, "Delete stays apart, on the leading side")
        expectSideBySideAtTheTrailingEdge(Array(noteFrames.frames.dropFirst()), edges: noteFrames.edges, "Segment note")

        let notice = RemoteAIAcknowledgementSheet(serviceName: "OpenAI", onAccept: {}, onCancel: {})
            .environment(\.locale, locale)
        let noticeFrames = try frames(of: ["AIServices.Button.CancelAcknowledge", "AIServices.Button.Acknowledge"], in: notice, model: model, width: 460)
        expectSideBySideAtTheTrailingEdge(noticeFrames.frames, edges: noticeFrames.edges, "Transcripts leave this Mac")
    }
}
