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
}
