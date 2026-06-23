import Foundation

enum ChapterTitle {
    static func clean(_ value: String) -> String {
        var result = value.trimmingCharacters(in: .whitespaces)
        while let first = result.first, "-—–•\"'*_".contains(first) {
            result = String(result.dropFirst()).trimmingCharacters(in: .whitespaces)
        }
        while let last = result.last, "-—–•\"'*_".contains(last) {
            result = String(result.dropLast()).trimmingCharacters(in: .whitespaces)
        }
        return result
    }
}
