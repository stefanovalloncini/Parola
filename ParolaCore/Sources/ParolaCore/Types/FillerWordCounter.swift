import Foundation

public enum FillerWordCounter {
    public static let defaultFillers: [String] = [
        "um", "uh", "uhm", "er", "erm",
        "like", "basically", "actually", "literally", "really",
        "you know", "i mean", "sort of", "kind of",
        "so", "well",
    ]

    public static func count(in text: String, fillers: [String] = defaultFillers) -> Int {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return 0 }
        let flattened = trimmed.lowercased().map { ch -> Character in
            (ch.isLetter || ch.isNumber || ch.isWhitespace) ? ch : " "
        }
        let haystack = " " + String(flattened).replacingOccurrences(of: "\n", with: " ") + " "
        var total = 0
        for filler in fillers {
            let needle = " \(filler) "
            var range = haystack.startIndex..<haystack.endIndex
            while let hit = haystack.range(of: needle, range: range) {
                total += 1
                range = haystack.index(before: hit.upperBound)..<haystack.endIndex
            }
        }
        return total
    }
}
