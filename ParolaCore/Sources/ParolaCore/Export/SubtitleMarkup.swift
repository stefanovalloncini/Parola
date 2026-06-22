import Foundation

enum SubtitleMarkup {
    static func stripInlineTags(_ line: String) -> String {
        guard line.contains("<") else { return line }
        var out = ""
        out.reserveCapacity(line.count)
        var inside = false
        for ch in line {
            if ch == "<" { inside = true; continue }
            if ch == ">" { inside = false; continue }
            if !inside { out.append(ch) }
        }
        return out
    }
}
