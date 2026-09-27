import Foundation
import ParolaCore

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

    /// Takes buffer into the recording scratch directory, so its volume's headroom is the one that matters.
    nonisolated static func systemFreeDiskSpace() -> Int64? {
        let values = try? existingAncestor(of: RecordingScratch.directory)
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    /// The scratch folder is made with the first take; until then its nearest existing parent names the volume.
    nonisolated static func existingAncestor(of url: URL) -> URL {
        var candidate = url
        while !FileManager.default.fileExists(atPath: candidate.path), candidate.pathComponents.count > 1 {
            candidate.deleteLastPathComponent()
        }
        return candidate
    }

    /// The query counts purgeable space and takes 17–34 ms, so it never runs on the main thread.
    nonisolated static func freeDiskSpace(_ provider: @escaping @Sendable () -> Int64?) async -> Int64? {
        (try? await offMainIO(qos: .userInitiated) { provider() }) ?? nil
    }

    nonisolated static func diskSpaceRefusalMessage(bundle: Bundle = .main) -> String {
        String(localized: "Not enough free disk space to record. Free up at least 200 MB and try again.", bundle: bundle)
    }

    func passesPreRecordingDiskCheck() async -> Bool {
        switch Self.diskSpaceVerdict(freeBytes: await Self.freeDiskSpace(freeDiskSpaceProvider)) {
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

    func checkRecordingDiskSpace() async {
        guard case .recording = phase else { return }
        let freeBytes = await Self.freeDiskSpace(freeDiskSpaceProvider)
        // The take can end while the volume is statted.
        guard case .recording = phase else { return }
        switch Self.diskSpaceVerdict(freeBytes: freeBytes) {
        case .refuse:
            stopRecordingAndTranscribe()
        case .warn:
            if !recordingDiskSpaceLow { recordingDiskSpaceLow = true }
        case .ok:
            if recordingDiskSpaceLow { recordingDiskSpaceLow = false }
        }
    }
}
