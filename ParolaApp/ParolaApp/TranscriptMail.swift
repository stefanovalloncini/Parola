import Foundation
import ParolaCore

enum TranscriptMail {
    static func mailtoURL(title: String, transcript: Transcript) -> URL? {
        var components = URLComponents(string: "mailto:")
        components?.queryItems = [
            URLQueryItem(name: "subject", value: title),
            URLQueryItem(name: "body", value: TranscriptTimestampedText.render(transcript)),
        ]
        return components?.url
    }
}
