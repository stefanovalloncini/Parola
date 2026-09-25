import Foundation
import ParolaCore

extension AppModel {

    enum YtDlpUpdateOffer: Equatable {
        case none
        case update
        case updating
        case command(String)
        case manual
        case updated(String)
    }

    var ytDlpUpdateOffer: YtDlpUpdateOffer {
        Self.ytDlpUpdateOffer(
            for: failedLinkDownload, route: ytDlpUpdateRoute, installed: ytDlpVersion, updating: ytDlpUpdating, now: Date()
        )
    }

    nonisolated static func ytDlpUpdateOffer(
        for failure: LinkDownloadFailure?,
        route: YtDlpInstaller.UpdateRoute?,
        installed: YtDlpVersion?,
        updating: Bool,
        now: Date
    ) -> YtDlpUpdateOffer {
        guard let failure, failure.ytDlpIsStale, let route else { return .none }
        if updating { return .updating }
        if let installed, !installed.isStale(asOf: now) { return .updated(installed.text) }
        switch route {
        case .homebrew: return .update
        case .command(let command): return .command(command)
        case .manual: return .manual
        }
    }

    /// A failed run has just asked yt-dlp for its version, which is newer news than the last Settings visit.
    func noteYtDlp(from failure: LinkDownloadFailure) {
        refreshYtDlpAvailability()
        guard !ytDlpUpdating else { return }
        if let version = failure.ytDlpVersion, version != ytDlpVersion { ytDlpVersion = version }
        if failure.ytDlpIsStale { ytDlpUpdateError = nil }
    }

    nonisolated static func linkFailureMessage(_ failure: LinkDownloadFailure, bundle: Bundle = .main) -> String {
        let hint = failure.ytDlpIsStale
            ? staleYtDlpSentence(failure.ytDlpVersion, bundle: bundle)
            : linkFailureHint(failure.reason, bundle: bundle)
        return [linkFailureHeadline(failure, bundle: bundle), hint].compactMap { $0 }.joined(separator: " ")
    }

    private nonisolated static func linkFailureHeadline(_ failure: LinkDownloadFailure, bundle: Bundle) -> String {
        switch failure.reason {
        case .refused(let status):
            switch (failure.site, status) {
            case (let site?, let status?):
                return String(localized: "\(site) refused the download (HTTP \(status)).", bundle: bundle)
            case (let site?, nil):
                return String(localized: "\(site) refused the download.", bundle: bundle)
            case (nil, let status?):
                return String(localized: "The site refused the download (HTTP \(status)).", bundle: bundle)
            case (nil, nil):
                return String(localized: "The site refused the download.", bundle: bundle)
            }
        case .unavailable(.removed):
            return String(localized: "This video can't be downloaded. It may have been removed.", bundle: bundle)
        case .unavailable(.privateVideo):
            return String(localized: "This video can't be downloaded because it's private.", bundle: bundle)
        case .unavailable(.membersOnly):
            return String(localized: "This video can't be downloaded because it's for channel members only.", bundle: bundle)
        case .unavailable(.ageRestricted):
            return String(localized: "This video can't be downloaded because it's age-restricted.", bundle: bundle)
        case .unavailable(.regionLocked):
            return String(localized: "This video can't be downloaded because it isn't available in your country.", bundle: bundle)
        case .unreachable:
            guard let site = failure.site else { return String(localized: "Couldn't reach the site.", bundle: bundle) }
            return String(localized: "Couldn't reach \(site).", bundle: bundle)
        case .timedOut(let seconds):
            return String(localized: "The download didn't finish within \(seconds) seconds.", bundle: bundle)
        case .noCaptions:
            return String(localized: "This video has no captions. Transcribe it instead.", bundle: bundle)
        case .noAudio:
            return String(localized: "yt-dlp finished without saving any audio.", bundle: bundle)
        case .unsupportedLink:
            return String(localized: "yt-dlp can't download from this site.", bundle: bundle)
        case .toolMissing:
            return String(localized: "yt-dlp isn't installed. Install it in Settings › Integrations.", bundle: bundle)
        case .toolFailedToStart:
            return String(localized: "Parola couldn't start yt-dlp.", bundle: bundle)
        case .toolError(let detail):
            return String(localized: "yt-dlp failed: \(detail)", bundle: bundle)
        case .toolExited(let status):
            return String(localized: "yt-dlp stopped with exit status \(status).", bundle: bundle)
        }
    }

    private nonisolated static func linkFailureHint(_ reason: LinkDownloadFailure.Reason, bundle: Bundle) -> String? {
        switch reason {
        case .refused:
            return String(localized: "Try again later.", bundle: bundle)
        case .unreachable, .timedOut:
            return String(localized: "Check your internet connection and try again.", bundle: bundle)
        default:
            return nil
        }
    }

    private nonisolated static func staleYtDlpSentence(_ version: YtDlpVersion?, bundle: Bundle) -> String {
        guard let version else {
            return String(localized: "Your yt-dlp is out of date — update it and try again.", bundle: bundle)
        }
        return String(localized: "Your yt-dlp (\(version.text)) is out of date — update it and try again.", bundle: bundle)
    }
}
