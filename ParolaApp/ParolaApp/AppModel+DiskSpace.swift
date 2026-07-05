import Foundation

extension AppModel {

    enum DiskSpaceVerdict: Equatable {
        case ok
        case warn
        case refuse
    }

    nonisolated static let diskSpaceWarnFloorBytes: Int64 = 1_000_000_000
    nonisolated static let diskSpaceRefuseFloorBytes: Int64 = 200_000_000

    /// nil (the volume couldn't be statted) counts as ok: never block a recording on a failed probe.
    nonisolated static func diskSpaceVerdict(freeBytes: Int64?) -> DiskSpaceVerdict {
        guard let freeBytes else { return .ok }
        if freeBytes < diskSpaceRefuseFloorBytes { return .refuse }
        if freeBytes < diskSpaceWarnFloorBytes { return .warn }
        return .ok
    }

    /// Recordings buffer into the temp directory, so that volume's headroom is the one that matters.
    nonisolated static func systemFreeDiskSpace() -> Int64? {
        let values = try? FileManager.default.temporaryDirectory
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    nonisolated static func diskSpaceRefusalMessage(bundle: Bundle = .main) -> String {
        String(localized: "Not enough free disk space to record. Free up at least 200 MB and try again.", bundle: bundle)
    }

    func applyPreRecordingDiskCheck() -> Bool {
        switch Self.diskSpaceVerdict(freeBytes: freeDiskSpaceProvider()) {
        case .refuse:
            phase = .failed(message: Self.diskSpaceRefusalMessage())
            return false
        case .warn:
            recordingDiskSpaceLow = true
            return true
        case .ok:
            recordingDiskSpaceLow = false
            return true
        }
    }

    func checkRecordingDiskSpace() {
        guard case .recording = phase else { return }
        switch Self.diskSpaceVerdict(freeBytes: freeDiskSpaceProvider()) {
        case .refuse:
            stopRecordingAndTranscribe()
        case .warn:
            if !recordingDiskSpaceLow { recordingDiskSpaceLow = true }
        case .ok:
            if recordingDiskSpaceLow { recordingDiskSpaceLow = false }
        }
    }
}
