import Foundation
import Testing
@testable import ParolaCore

@Suite("Log error sanitization")
struct LogErrorKindTests {
    @Test("an NSError renders as domain and code only")
    func nsErrorIsDomainAndCode() {
        let error = NSError(domain: NSCocoaErrorDomain, code: 260, userInfo: [
            NSFilePathErrorKey: "/Users/realname/Music/board-meeting-q3.m4a",
            NSLocalizedDescriptionKey: "The file “board-meeting-q3.m4a” couldn’t be opened.",
        ])
        let text = LogErrorKind.describe(error)
        #expect(text == "NSCocoaErrorDomain.260")
        #expect(text.contains("board-meeting") == false)
        #expect(text.contains("/Users") == false)
    }

    @Test("a ParolaError carrying a URL renders no path")
    func parolaErrorDropsPaths() {
        let url = URL(fileURLWithPath: "/Users/realname/Music/board-meeting-q3.m4a")
        let error = ParolaError.audioLoadFailed(url, underlying: "No such file")
        let text = LogErrorKind.describe(error)
        #expect(text == "ParolaError.audioLoadFailed")
        #expect(text.contains("board-meeting") == false)
        #expect(text.contains("/Users") == false)
    }

    @Test("a ParolaError carrying a laundered localizedDescription drops it")
    func parolaErrorDropsUnderlyingText() {
        let error = ParolaError.transcriptionFailed(
            "Apple Speech failed: file /Users/realname/x.m4a is unreadable"
        )
        let text = LogErrorKind.describe(error)
        #expect(text == "ParolaError.transcriptionFailed")
        #expect(text.contains("/Users") == false)
    }

    @Test("safe associated values survive")
    func safeAssociatedValuesSurvive() {
        #expect(LogErrorKind.describe(ParolaError.modelNotFound("whisper-v3"))
            == "ParolaError.modelNotFound(whisper-v3)")
        #expect(LogErrorKind.describe(ParolaError.featureDisabled(.dictation))
            == "ParolaError.featureDisabled(dictation)")
    }

    @Test("a checksum mismatch drops the file name but keeps the shape")
    func checksumDropsFileName() {
        let error = ParolaError.modelChecksumMismatch(
            file: "board-meeting-q3.m4a", expected: "abc", got: "def"
        )
        let text = LogErrorKind.describe(error)
        #expect(text == "ParolaError.modelChecksumMismatch")
        #expect(text.contains("board-meeting") == false)
    }

    @Test("cancellation is distinguishable from failure")
    func cancellationIsItsOwnKind() {
        #expect(LogErrorKind.describe(CancellationError()) == "cancelled")
        #expect(LogErrorKind.describe(URLError(.cancelled)) == "cancelled")
    }

    @Test("an unknown error renders as its type name only")
    func unknownRendersTypeName() {
        struct SecretError: Error { let path = "/Users/realname/secret.m4a" }
        let text = LogErrorKind.describe(SecretError())
        #expect(text.contains("SecretError"))
        #expect(text.contains("/Users") == false)
    }

    @Test("LogValue.error routes through the sanitizer")
    func logValueUsesSanitizer() {
        let value = LogValue.error(ParolaError.transcriptionFailed("/Users/x"))
        #expect(value.text == "ParolaError.transcriptionFailed")
    }
}
