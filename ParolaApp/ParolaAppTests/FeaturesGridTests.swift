import Testing
@testable import Parola
import ParolaCore

@MainActor
@Suite("Introduction feature grid")
struct FeaturesGridTests {
    @Test("cards pair two to a row, an odd last one stays alone")
    func arrangementTable() {
        #expect(FeaturesScene.arrangement(count: 0) == [])
        #expect(FeaturesScene.arrangement(count: 1) == [[0]])
        #expect(FeaturesScene.arrangement(count: 2) == [[0, 1]])
        #expect(FeaturesScene.arrangement(count: 3) == [[0, 1], [2]])
        #expect(FeaturesScene.arrangement(count: 4) == [[0, 1], [2, 3]])
    }

    @Test("every deployment's rows fit two grid rows, in order")
    func arrangementCoversEveryRowCount() {
        for count in 0...4 {
            let rows = FeaturesScene.arrangement(count: count)
            #expect(rows.count <= 2)
            #expect(rows.flatMap(\.self) == Array(0..<count))
            #expect(rows.allSatisfy { $0.count <= 2 })
        }
    }

    @Test("the loop phase wraps every four seconds")
    func phaseTable() {
        #expect(FeatureVignettePhase.phase(at: 0) == 0)
        #expect(FeatureVignettePhase.phase(at: 2) == 0.5)
        #expect(FeatureVignettePhase.phase(at: 4) == 0)
        #expect(FeatureVignettePhase.phase(at: 5) == 0.25)
    }

    @Test("a ramp holds at both ends")
    func rampTable() {
        #expect(FeatureVignettePhase.ramp(0, from: 0.2, span: 0.2) == 0)
        #expect(abs(FeatureVignettePhase.ramp(0.3, from: 0.2, span: 0.2) - 0.5) < 1e-9)
        #expect(FeatureVignettePhase.ramp(1, from: 0.2, span: 0.2) == 1)
        #expect(FeatureVignettePhase.ramp(0.5, from: 0.2, span: 0) == 1)
    }

    @Test("a ramp's ease and pulse rest at both ends")
    func easeAndPulse() {
        #expect(FeatureVignettePhase.ease(0) == 0)
        #expect(FeatureVignettePhase.ease(1) == 1)
        #expect(FeatureVignettePhase.pulse(0, from: 0.1, span: 0.2) == 0)
        #expect(FeatureVignettePhase.pulse(1, from: 0.1, span: 0.2) == 0)
        #expect(FeatureVignettePhase.pulse(0.2, from: 0.1, span: 0.2) == 1)
        #expect(FeatureVignettePhase.clearing(0) == 1)
        #expect(FeatureVignettePhase.clearing(1) == 1)
        #expect(FeatureVignettePhase.clearing(FeatureVignettePhase.resetSpan / 2) == 0.5)
    }

    @Test("every loop ends on the frame it began with")
    func loopsWrapOnTheSettledFrame() {
        #expect(TranscribeFrame(phase: 0) == TranscribeFrame(phase: 1))
        #expect(MeetingFrame(phase: 0) == MeetingFrame(phase: 1))
        #expect(CaptionsFrame(phase: 0) == CaptionsFrame(phase: 1))
        #expect(DictationFrame(phase: 0) == DictationFrame(phase: 1))
        for count in 1...6 {
            for index in 0..<count {
                #expect(DictationFrame.word(index, of: count, at: 0) == DictationFrame.word(index, of: count, at: 1))
            }
        }
    }

    @Test("the settled frame is the finished sketch, which is what reduce motion shows")
    func settledFrameIsFinished() {
        let transcribe = TranscribeFrame(phase: 1)
        #expect(transcribe.glyphOpacity == 1)
        #expect(transcribe.glyphOffset == 0)
        #expect(transcribe.lineOpacity == 1)
        #expect((0..<3).allSatisfy { transcribe.line($0) == 1 })

        let meeting = MeetingFrame(phase: 1)
        #expect(meeting.dot == 1)
        #expect(meeting.pillScale == 1)

        let dictation = DictationFrame(phase: 1)
        #expect(dictation.press == 0)
        #expect(!dictation.isHeld)
        #expect(dictation.caretVisible)
        #expect((0..<3).allSatisfy { DictationFrame.word($0, of: 3, at: 1) == 1 })

        let captions = CaptionsFrame(phase: 1)
        #expect(captions.caption == 1)
        #expect(captions.captionOffset == 0)
        #expect(captions.listening == 0)
    }

    @Test("the key stays down for as long as the words are landing")
    func keyIsHeldThroughThePhrase() {
        #expect(!DictationFrame(phase: 0).isHeld)
        #expect(DictationFrame(phase: DictationFrame.firstWord).isHeld)
        #expect(DictationFrame(phase: DictationFrame.lastWord).isHeld)
        #expect(!DictationFrame(phase: DictationFrame.lastWord + DictationFrame.pressTravel).isHeld)
        #expect(DictationFrame(phase: DictationFrame.lastWord).press == 1)
    }

    @Test("the captions panel never shows both of its states at once")
    func captionsNeverOverlap() {
        for step in 0...400 {
            let frame = CaptionsFrame(phase: Double(step) / 400)
            #expect(min(frame.listening, frame.caption) == 0)
        }
        #expect(CaptionsFrame(phase: 0.25).listening == 1)
        #expect(CaptionsFrame(phase: 0.25).caption == 0)
    }

    @Test("the captions panel is never blank for more than a frame")
    func captionsPanelStaysLegible() {
        let frames = Int((FeatureVignettePhase.period / FeatureVignettePhase.frameInterval).rounded())
        let blank = (0..<frames)
            .map { CaptionsFrame(phase: Double($0) / Double(frames)) }
            .filter { max($0.listening, $0.caption) < 0.1 }
        // One handover each way, each allowed a single frame at the zero crossing the no-overlap rule forces.
        #expect(blank.count <= 2)
    }

    @Test("the dictated phrase lands by the end of the hold, whatever its word count")
    func wordStrideFollowsTheWordCount() {
        for count in 1...6 {
            #expect(DictationFrame.word(count - 1, of: count, at: DictationFrame.lastWord) == 1)
            #expect(DictationFrame.word(0, of: count, at: DictationFrame.firstWord) == 0)
        }
    }

    @Test("no two vignettes reach the same point of the loop together")
    func loopsAreOffsetFromEachOther() {
        let offsets = FeatureVignetteKind.allCases.map(\.phaseOffset)
        #expect(offsets.allSatisfy { $0 >= 0 && $0 < FeatureVignettePhase.period })
        for (index, offset) in offsets.enumerated() {
            for other in offsets[(index + 1)...] {
                let gap = abs(offset - other)
                #expect(min(gap, FeatureVignettePhase.period - gap) >= 0.8)
            }
        }
    }

    @Test("every feature row has a vignette")
    func everyRowHasAVignette() {
        for item in FeaturesScene.rows(features: .all) {
            #expect(FeatureVignetteKind(symbol: item.symbol) != nil)
        }
        #expect(FeatureVignetteKind(symbol: "questionmark") == nil)
    }
}
