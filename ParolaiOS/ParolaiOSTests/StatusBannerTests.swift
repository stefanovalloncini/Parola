import Foundation
import Testing
@testable import Parola

@Suite("StatusBanner copy")
struct StatusBannerTests {
    @Test("downloading shows model name and percent")
    func downloading() {
        let copy = StatusBannerCopy.text(for: .downloadingModel(name: "openai_whisper-tiny", progress: 0.42))
        #expect(copy == "Downloading openai_whisper-tiny · 42%")
    }

    @Test("loading shows model name")
    func loading() {
        let copy = StatusBannerCopy.text(for: .loadingModel(name: "openai_whisper-tiny"))
        #expect(copy == "Loading openai_whisper-tiny…")
    }

    @Test("transcribing shows file name")
    func transcribing() {
        let url = URL(fileURLWithPath: "/tmp/clip.wav")
        let copy = StatusBannerCopy.text(for: .transcribing(file: url))
        #expect(copy == "Transcribing clip.wav…")
    }

    @Test("idle and recording have no banner copy")
    func emptyPhases() {
        #expect(StatusBannerCopy.text(for: .idle) == nil)
        #expect(StatusBannerCopy.text(for: .recording) == nil)
    }

    @Test("failed surfaces the underlying message")
    func failed() {
        let copy = StatusBannerCopy.text(for: .failed(message: "no model"))
        #expect(copy == "no model")
    }
}
