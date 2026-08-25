import Foundation
import ParolaCore

/// The one answer to "what did the user just hand us". Every intake path — the window drop,
/// Open With, the Services menu, the open panel, the bridge — sorts its URLs through here, so
/// a `.mkv` or a Safari link means the same thing whichever pane is on screen.
enum DroppedFiles {

    enum Kind: Equatable, Sendable {
        case media(count: Int)
        case subtitles(count: Int)
        case projects(count: Int)
        case links(count: Int)
        case mixed(count: Int)
        case unsupported
    }

    /// Hovering classifies shallow (it runs on every drag entering the window); the drop itself
    /// walks the whole tree, matching what a watched folder would pick up.
    enum FolderDepth: Sendable {
        case shallow
        case recursive
    }

    struct Classification: Equatable, Sendable {
        var media: [URL] = []
        var subtitles: [URL] = []
        var projects: [URL] = []
        var links: [URL] = []

        var isEmpty: Bool {
            media.isEmpty && subtitles.isEmpty && projects.isEmpty && links.isEmpty
        }

        var files: [URL] { media + subtitles + projects }

        var kind: Kind {
            if isEmpty { return .unsupported }
            if !media.isEmpty {
                let others = subtitles.count + projects.count + links.count
                return others == 0 ? .media(count: media.count) : .mixed(count: media.count + others)
            }
            if !subtitles.isEmpty { return .subtitles(count: subtitles.count) }
            if !projects.isEmpty { return .projects(count: projects.count) }
            return .links(count: links.count)
        }
    }

    static let projectExtension = "parola"

    static func classify(_ urls: [URL], folders: FolderDepth = .recursive) -> Classification {
        var result = Classification()
        var seen = Set<String>()
        for url in urls {
            guard url.isFileURL else {
                if url.isYtDlpSupported, seen.insert(url.absoluteString).inserted {
                    result.links.append(url)
                }
                continue
            }
            for file in expand(url, folders: folders) {
                guard seen.insert(file.standardizedFileURL.path).inserted else { continue }
                switch role(of: file) {
                case .media: result.media.append(file)
                case .subtitle: result.subtitles.append(file)
                case .project: result.projects.append(file)
                case nil: break
                }
            }
        }
        return result
    }

    static func isProject(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == projectExtension
    }

    private enum Role {
        case media
        case subtitle
        case project
    }

    private static func role(of url: URL) -> Role? {
        if isProject(url) { return .project }
        if AppModel.isSubtitleImport(url) { return .subtitle }
        if FolderWatcher.isMediaFile(url) { return .media }
        return nil
    }

    private static func expand(_ url: URL, folders: FolderDepth) -> [URL] {
        guard isDirectory(url), !isProject(url) else { return [url] }
        let found = switch folders {
        case .shallow: topLevel(of: url)
        case .recursive: walk(url)
        }
        return found.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    private static func topLevel(of url: URL) -> [URL] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return contents.filter { role(of: $0) != nil }
    }

    private static func walk(_ url: URL) -> [URL] {
        guard let walker = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        var found: [URL] = []
        for case let child as URL in walker {
            if isProject(child) {
                walker.skipDescendants()
                found.append(child)
            } else if !isDirectory(child), role(of: child) != nil {
                found.append(child)
            }
        }
        return found
    }

    private static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
    }
}

extension DroppedFiles {

    /// What the split drop overlay offers for a payload, once the build's features and the
    /// current phase have had their say.
    enum ZonePlan: Equatable, Sendable {
        case split(count: Int)
        case transcribeOnly(count: Int)
        case queueOnly(count: Int)
        case importSubtitles(count: Int)
        case openProjects(count: Int)
        case transcribeLink
        case none
    }

    static func plan(
        for kind: Kind,
        batchEnabled: Bool,
        youtubeEnabled: Bool,
        arrivalsDeferred: Bool
    ) -> ZonePlan {
        switch kind {
        case .unsupported:
            return .none
        case .subtitles(let count):
            return .importSubtitles(count: count)
        case .projects(let count):
            return .openProjects(count: count)
        case .links:
            return youtubeEnabled ? .transcribeLink : .none
        case .media(let count), .mixed(let count):
            if !batchEnabled { return .transcribeOnly(count: count) }
            if arrivalsDeferred { return .queueOnly(count: count) }
            return .split(count: count)
        }
    }
}
