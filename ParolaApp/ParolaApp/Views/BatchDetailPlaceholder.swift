import Foundation

enum BatchDetailPlaceholder: Equatable {
    case running
    case selectFile
    case noTranscripts

    init(isRunning: Bool, hasCompletedJob: Bool) {
        if isRunning {
            self = .running
        } else if hasCompletedJob {
            self = .selectFile
        } else {
            self = .noTranscripts
        }
    }
}
