import Foundation

enum SubtitleMarkup {
    static func stripInlineTags(_ line: String) -> String {
        guard line.contains("<") else { return line }
        var out = ""
        out.reserveCapacity(line.count)
        var i = line.startIndex
        while i < line.endIndex {
            if line[i] == "<", let close = line[line.index(after: i)...].firstIndex(of: ">") {
                i = line.index(after: close)
            } else {
                out.append(line[i])
                i = line.index(after: i)
            }
        }
        return out
    }

    // Must run after tag stripping, else an escaped `&lt;b&gt;` is eaten as a tag; `&amp;` last so `&amp;lt;` stays `&lt;`.
    static func decodeEntities(_ s: String) -> String {
        guard s.contains("&") else { return s }
        return s
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&amp;", with: "&")
    }
}
