import Foundation

public enum ReadingTime {
    public static let wordsPerMinute = 200

    public static func minutes(forWordCount wordCount: Int) -> Int {
        guard wordCount > 0 else { return 0 }
        return max(1, Int(ceil(Double(wordCount) / Double(wordsPerMinute))))
    }

    public static func label(forMinutes minutes: Int) -> String {
        guard minutes > 0 else { return "—" }
        if minutes < 60 { return "\(minutes) min" }
        let h = minutes / 60
        let m = minutes % 60
        if m == 0 { return "\(h)h" }
        return "\(h)h \(m)m"
    }
}
