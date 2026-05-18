import Foundation

enum ChatAttachment {
    static let defaultMaxCharacters: Int = 8_000
    static let textExtensions: Set<String> = ["txt", "md", "markdown", "json", "csv", "tsv", "log", "vtt", "srt", "html"]

    static func attach(
        input: String,
        filename: String,
        content: String,
        maxCharacters: Int = defaultMaxCharacters
    ) -> String {
        let trimmedContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
        let (capped, didTruncate) = cap(trimmedContent, to: maxCharacters)
        var block = "Context from \(filename):\n\(capped)"
        if didTruncate {
            block += "\n[…truncated]"
        }
        let trimmedInput = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedInput.isEmpty { return block }
        return trimmedInput + "\n\n" + block
    }

    static func isReadableTextFile(_ url: URL) -> Bool {
        textExtensions.contains(url.pathExtension.lowercased())
    }

    private static func cap(_ text: String, to limit: Int) -> (String, Bool) {
        guard text.count > limit else { return (text, false) }
        let index = text.index(text.startIndex, offsetBy: limit)
        return (String(text[..<index]), true)
    }
}
