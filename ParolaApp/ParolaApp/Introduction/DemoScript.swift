import Foundation

/// Precomputed transcript of the introduction's demo clip, written by scripts/build-intro-clip.sh.
struct DemoScript: Codable, Equatable {
    struct Word: Codable, Equatable {
        var text: String
        var start: Double
        var end: Double
    }

    var text: String
    var speaker: String
    var duration: Double
    var levelRate: Double
    var levels: [Float]
    var words: [Word]

    func visibleWordCount(at time: Double) -> Int {
        words.count { $0.start <= time }
    }

    func level(at time: Double) -> Float {
        let index = Int(time * levelRate)
        guard levels.indices.contains(index) else { return 0 }
        return levels[index]
    }

    /// One level per brand bar, the centre bar carrying the level now and the ones outside it running behind.
    func barLevels(at time: Double, lagPerBar: Double = BrandWaveform.levelLagPerBar) -> [Float] {
        let centre = BrandWaveform.barCount / 2
        return (0..<BrandWaveform.barCount).map { index in
            level(at: time - Double(abs(index - centre)) * lagPerBar)
        }
    }

    /// The last `window` levels up to `time`, padded with silence where the clip has nothing to give.
    func levels(window: Int, endingAt time: Double) -> [Float] {
        let last = Int(time * levelRate)
        return (0..<max(0, window)).map { offset in
            let index = last - window + 1 + offset
            return levels.indices.contains(index) ? levels[index] : 0
        }
    }

    /// Stands in when the bundled clip is missing, so the card still reads instead of going blank.
    static let placeholder = DemoScript(
        text: """
        This is Parola. It listens to a recording and writes down every word. Right here on your Mac. \
        Nothing leaves this computer.
        """,
        speaker: "Speaker 1",
        duration: 0,
        levelRate: 20,
        levels: [],
        words: []
    )
}

struct DemoClip {
    let script: DemoScript
    let audioURL: URL

    static func bundled(
        preferredLanguages: [String] = Bundle.main.preferredLocalizations,
        bundle: Bundle = .main
    ) -> DemoClip? {
        let code = preferredLanguages.first.flatMap { Locale(identifier: $0).language.languageCode?.identifier }
        let name = code == "it" ? "demo-it" : "demo-en"
        guard let audioURL = bundle.url(forResource: name, withExtension: "m4a"),
              let scriptURL = bundle.url(forResource: name, withExtension: "json"),
              let data = try? Data(contentsOf: scriptURL),
              let script = try? JSONDecoder().decode(DemoScript.self, from: data)
        else { return nil }
        return DemoClip(script: script, audioURL: audioURL)
    }
}
