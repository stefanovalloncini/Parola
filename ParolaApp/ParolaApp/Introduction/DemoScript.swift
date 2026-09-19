import Foundation

/// The precomputed transcript of the introduction's demo clip: what the words are, when each one
/// lands, and how loud the voice is along the way. Written by scripts/build-intro-clip.sh, so the
/// introduction can show a transcription without running a model.
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

    /// Stands in when the bundled clip is missing, so the card still reads instead of going blank.
    static let placeholder = DemoScript(
        text: """
        This is Parola. It listens to a recording and writes down every word, right here on your Mac. \
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
        preferredLanguages: [String] = Locale.preferredLanguages,
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
