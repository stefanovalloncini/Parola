import Foundation
import UniformTypeIdentifiers
import ParolaCore

enum BatchMediaKind {
    case audio
    case video

    /// Intake's lists win: `UTType(filenameExtension: "mkv")` is dynamic and conforms to neither `.movie` nor `.video`.
    init(url: URL) {
        let ext = url.pathExtension.lowercased()
        if FolderWatcher.videoExtensions.contains(ext) {
            self = .video
        } else if FolderWatcher.audioExtensions.contains(ext) {
            self = .audio
        } else if let type = UTType(filenameExtension: ext) {
            self = type.conforms(to: .movie) || type.conforms(to: .video) ? .video : .audio
        } else {
            self = .audio
        }
    }
}
