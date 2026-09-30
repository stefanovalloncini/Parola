import Foundation
import ParolaCore

struct StaleYtDlpFailure: LocalizedError, CustomStringConvertible {
    let failure: LinkDownloadFailure
    let updateCommand: String

    var description: String { "\(failure.message)\nTo update yt-dlp, run: \(updateCommand)" }
    var errorDescription: String? { description }
}

func addingYtDlpUpdateHint(
    to error: any Error,
    route: () -> YtDlpUpdateRoute? = { YtDlpLocator.locate().map(YtDlpUpdateRoute.init(ytDlpPath:)) }
) -> any Error {
    guard let parolaError = error as? ParolaError,
          case .linkDownloadFailed(let failure) = parolaError,
          failure.ytDlpIsStale,
          let command = route()?.shellCommand
    else { return error }
    return StaleYtDlpFailure(failure: failure, updateCommand: command)
}
