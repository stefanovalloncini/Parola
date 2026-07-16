import Foundation

enum SubtitleMarkup {
    static func stripInlineTags(_ line: String) -> String {
        guard line.contains("<") else { return line }
        var out = ""
        out.reserveCapacity(line.count)
        var i = line.startIndex
        while i < line.endIndex {
            let afterOpen = line.index(after: i)
            // Only strip a real tag: `<c>`, `</v>`, `<font …>`, or a VTT timestamp tag `<00:00:01.000>`.
            // A bare comparison like `x < 5 and y > 3` isn't a tag, so leave it (and the text between) intact.
            if line[i] == "<",
               afterOpen < line.endIndex,
               isTagStart(line[afterOpen]),
               let close = line[afterOpen...].firstIndex(of: ">") {
                i = line.index(after: close)
            } else {
                out.append(line[i])
                i = afterOpen
            }
        }
        return out
    }

    private static func isTagStart(_ c: Character) -> Bool {
        c == "/" || c.isLetter || c.isNumber
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
