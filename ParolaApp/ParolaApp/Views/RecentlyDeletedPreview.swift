import Foundation
import ParolaCore

func readTranscriptText(at bundleURL: URL) async -> String {
    let transcriptURL = bundleURL.appendingPathComponent("transcript.json")
    guard let data = try? Data(contentsOf: transcriptURL),
          let transcript = try? JSONDecoder().decode(Transcript.self, from: data)
    else { return "" }
    return transcript.text
}
