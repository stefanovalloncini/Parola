import Foundation

struct CustomModelSource: Equatable, Sendable, Hashable {
    let repo: String
    let revision: String

    init(repo: String, revision: String = "main") {
        self.repo = repo
        self.revision = revision
    }

    var displayName: String {
        repo.split(separator: "/").last.map(String.init) ?? repo
    }

    static func parse(_ input: String) -> CustomModelSource? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let url = URL(string: trimmed), let host = url.host, !host.isEmpty {
            guard host == "huggingface.co" else { return nil }
            return parsePath(url.path)
        }
        return parseRepo(trimmed)
    }

    private static func parsePath(_ path: String) -> CustomModelSource? {
        let components = path
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
        guard components.count >= 2 else { return nil }
        let owner = components[0]
        let repo = components[1]
        var revision = "main"
        if components.count >= 4, components[2] == "tree" {
            revision = components[3]
        }
        return CustomModelSource(repo: "\(owner)/\(repo)", revision: revision)
    }

    private static func parseRepo(_ value: String) -> CustomModelSource? {
        let trimmed = value.trimmingCharacters(in: CharacterSet(charactersIn: " /"))
        let parts = trimmed.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard parts.count == 2 else { return nil }
        return CustomModelSource(repo: "\(parts[0])/\(parts[1])")
    }
}
