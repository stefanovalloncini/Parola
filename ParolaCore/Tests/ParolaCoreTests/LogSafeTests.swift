import Foundation
import Testing
@testable import ParolaCore
@testable import ParolaDictation

@Suite("Log safe conformances")
struct LogSafeTests {
    @Test(
        "export formats render as their raw value",
        arguments: [
            (ExportFormat.txt, "txt"), (.srt, "srt"), (.vtt, "vtt"), (.json, "json"),
            (.jsonl, "jsonl"), (.md, "md"), (.html, "html"), (.csv, "csv"), (.tsv, "tsv"),
            (.docx, "docx"), (.pdf, "pdf"), (.fcpxml, "fcpxml"), (.lrc, "lrc"),
        ]
    )
    func exportFormatTokens(format: ExportFormat, expected: String) {
        #expect(format.logToken == expected)
    }

    @Test("every export format has a token")
    func everyExportFormatHasAToken() {
        #expect(ExportFormat.allCases.allSatisfy { !$0.logToken.isEmpty })
    }

    @Test(
        "entry categories render as their raw value",
        arguments: [
            (EntryCategory.transcription, "transcription"), (.meeting, "meeting"),
            (.dictation, "dictation"),
        ]
    )
    func entryCategoryTokens(category: EntryCategory, expected: String) {
        #expect(category.logToken == expected)
    }

    @Test(
        "batch job statuses render as their raw value",
        arguments: [
            (BatchJob.Status.pending, "pending"), (.transcribing, "transcribing"),
            (.done, "done"), (.failed, "failed"), (.cancelled, "cancelled"),
        ]
    )
    func batchStatusTokens(status: BatchJob.Status, expected: String) {
        #expect(status.logToken == expected)
    }

    @Test(
        "transcribe stages render as their case name",
        arguments: [
            (TranscribeStage.preparingAudio, "preparingAudio"),
            (TranscribeStage.transcribing, "transcribing"),
        ]
    )
    func transcribeStageTokens(stage: TranscribeStage, expected: String) {
        #expect(stage.logToken == expected)
    }

    @Test(
        "system audio permission states render as their case name",
        arguments: [
            (SystemAudioRecordingPermission.granted, "granted"),
            (.undetermined, "undetermined"), (.denied, "denied"),
        ]
    )
    func systemAudioPermissionTokens(
        permission: SystemAudioRecordingPermission, expected: String
    ) {
        #expect(permission.logToken == expected)
    }

    @Test("a catalog variant renders the same token as ModelToken")
    func variantMatchesModelToken() throws {
        let variant = try #require(ModelCatalog.variant(id: "openai_whisper-large-v3_turbo"))
        #expect(variant.logToken == "openai_whisper-large-v3_turbo")
        #expect(variant.logToken == ModelToken(variant.id).logToken)
    }

    @Test("a variant outside the catalog is redacted")
    func uncatalogedVariantIsRedacted() {
        let variant = ModelVariant(
            id: "/Users/realname/secret-model",
            displayName: "Secret",
            tagline: "",
            engineID: .whisperKit,
            sizeBytes: 1,
            downloadSource: ModelDownloadSource(huggingFaceRepo: "repo", subpath: ""),
            category: .specialized,
            speedTier: .fast,
            qualityTier: .good
        )
        #expect(variant.logToken == "unrecognized")
    }

    @Test("Int64 renders like Int")
    func int64RendersLikeInt() {
        #expect(Int64(4_823).logToken == "4823")
        #expect(Int64(-1).logToken == "-1")
        #expect(Int64.max.logToken == String(Int64.max))
    }

    @Test(
        "a language code the allowlist knows survives",
        arguments: ["en", "it", "pt-BR", "zh-Hans"]
    )
    func knownLanguageTokens(code: String) {
        #expect(LanguageToken(code).logToken == code)
    }

    @Test("a language token outside the allowlist renders the fallback")
    func unknownLanguageTokenIsRedacted() {
        #expect(LanguageToken("../../etc").logToken == "unrecognized")
        #expect(LanguageToken("/Users/realname/notes.txt").logToken == "unrecognized")
    }

    @Test(
        "dictation modes render as their raw value",
        arguments: [
            (DictationMode.pushToTalk, "pushToTalk"), (.toggle, "toggle"), (.hybrid, "hybrid"),
        ]
    )
    func dictationModeTokens(mode: DictationMode, expected: String) {
        #expect(mode.logToken == expected)
    }

    @Test(
        "dictation states render as their case name",
        arguments: [
            (DictationCoordinator.State.idle, "idle"), (.listening, "listening"),
            (.transcribing, "transcribing"), (.failed("boom"), "failed"),
        ]
    )
    func dictationStateTokens(state: DictationCoordinator.State, expected: String) {
        #expect(state.logToken == expected)
    }

    @Test("a failed dictation state never renders its payload")
    func dictationFailurePayloadStaysOut() {
        let state = DictationCoordinator.State.failed("/Users/x/secret")
        #expect(state.logToken == "failed")
        let message: LogMessage = "dictation \(state)"
        #expect(message.rendered == "dictation failed")
        #expect(LogValue.safe(state).text == "failed")
    }
}
