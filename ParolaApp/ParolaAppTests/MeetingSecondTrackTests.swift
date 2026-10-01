import AVFoundation
import Foundation
import Testing
@testable import Parola
import ParolaCore
import ParolaTestSupport

extension TranscriberMockSuites {
    @MainActor
    @Suite("Meeting second track", .serialized)
    struct MeetingSecondTrackTests {

        private func makeModel(
            libraryURL: URL = makeTempLibraryURL("second-track"), defaults: UserDefaults = temporaryDefaults()
        ) -> AppModel {
            let model = AppModel(bootstrap: AppBootstrap(
                mode: .test,
                library: libraryURL,
                defaultsOverride: defaults,
                sideEffects: [],
                filePicker: TestFilePicker()
            ))
            model.recordingCountInSeconds = 0
            model.freeDiskSpaceProvider = { 50_000_000_000 }
            model.cardMetadataOperation = { _ in nil }
            return model
        }

        private func inflight(_ library: URL) throws -> URL {
            let folder = library.appendingPathComponent("inflight", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            return folder
        }

        private func age(_ file: URL, by seconds: TimeInterval) throws {
            try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-seconds)], ofItemAtPath: file.path)
        }

        private func writeLegacyCheckpoint(_ checkpoint: RecoveryCheckpoint, library: URL) throws {
            try JSONEncoder().encode(checkpoint).write(to: library.appendingPathComponent("recovery.json"))
        }

        // MARK: - The setting

        @Test("recording your microphone in meetings starts on, is kept, resets with its pane, and the bridge may set it")
        func micSettingStartsOn() {
            let defaults = temporaryDefaults()
            let model = makeModel(defaults: defaults)
            #expect(model.meetingRecordsMicrophone)

            model.meetingRecordsMicrophone = false
            #expect(defaults.object(forKey: "meetingRecordsMicrophone") as? Bool == false)
            model.reloadSettings()
            #expect(!model.meetingRecordsMicrophone)

            #expect(SettingsPaneScope.recordMeetings.defaultsKeys.contains("meetingRecordsMicrophone"))
            #expect(ParolaAutomationServer.writableSettingKeys.contains("meetingRecordsMicrophone"))
            for key in SettingsPaneScope.recordMeetings.defaultsKeys { defaults.removeObject(forKey: key) }
            model.reloadSettings()
            #expect(model.meetingRecordsMicrophone)
            #expect(SettingsSidebarCatalog.matches(route: .recordMeetings, query: "microphone"))
        }

        @Test("the setting reads in Italian")
        func micSettingReadsInItalian() throws {
            let path = try #require(Bundle.main.path(forResource: "it", ofType: "lproj"))
            let italian = try #require(Bundle(path: path))
            #expect(String(localized: "Record my microphone in meetings", bundle: italian) == "Registra il mio microfono nelle riunioni")
        }

        // MARK: - The checkpoint and the sweep

        @Test("a meeting's checkpoint names its microphone track and where it starts, and counts it among its files")
        func checkpointCarriesTheMicTrack() throws {
            let take = URL(fileURLWithPath: "/tmp/inflight/parola-system-1.wav")
            let mic = URL(fileURLWithPath: "/tmp/inflight/parola-meetmic-1.wav")
            let checkpoint = RecoveryCheckpoint(
                kind: .recording, startedAt: Date(), modelName: "m", audioURL: take, source: .systemAudio, category: .meeting,
                companionAudioURL: mic, companionStartOffset: 0.25
            )

            let decoded = try JSONDecoder().decode(RecoveryCheckpoint.self, from: try JSONEncoder().encode(checkpoint))

            #expect(decoded.companionAudioURL == mic)
            #expect(decoded.companionStartOffset == 0.25)
            #expect(decoded.referencedPaths.first == take.resolvingSymlinksInPath().path, "the take's own file still comes first")
            #expect(decoded.referencedPaths.contains(mic.resolvingSymlinksInPath().path))
        }

        @Test("a take's checkpoint is written with the microphone track recording beside it")
        func liveCheckpointNamesTheMicTrack() async throws {
            let model = makeModel()
            let take = URL(fileURLWithPath: "/tmp/parola-system-live.wav")
            let mic = URL(fileURLWithPath: "/tmp/parola-meetmic-live.wav")
            model.beginRecordingRecovery()
            model.liveRecordingAudioURL = take
            model.liveCompanionAudioURL = mic
            model.liveCompanionStartOffset = 0.1

            model.writeRecordingCheckpoint()
            await model.pendingRecoveryWrite?.value

            let written = try JSONDecoder().decode(
                RecoveryCheckpoint.self, from: try Data(contentsOf: try #require(model.activeRecoveryFileURL))
            )
            #expect(written.audioURL == take)
            #expect(written.companionAudioURL == mic)
            #expect(written.companionStartOffset == 0.1)
            model.endActiveRecovery()
        }

        @Test("the microphone track recording now is a working file in use, which the heartbeat keeps fresh")
        func liveMicTrackIsInUse() throws {
            let library = makeTempLibraryURL("second-track-in-use")
            let folder = try inflight(library)
            let model = makeModel(libraryURL: library)
            let mic = try makeTakeWAV("mic-in-use", in: folder, prefix: RecordingScratch.meetingMicPrefix)
            try age(mic, by: 3_600)

            model.liveCompanionAudioURL = mic
            model.touchTakeFilesInUse()

            #expect(model.inflightFileInUse(mic))
            let modified = try #require(try mic.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
            #expect(modified > Date().addingTimeInterval(-60))
        }

        @Test("the sweep keeps a microphone track while its take is in the folder, and takes an orphaned one only after two days")
        func sweepKeepsTheMicTrackWithItsTake() {
            let folder = URL(fileURLWithPath: "/tmp/parola-sweep", isDirectory: true)
            let now = Date()
            let days = now.addingTimeInterval(-3 * 86_400)
            let take = folder.appendingPathComponent("parola-system-AAA.wav")
            let paired = folder.appendingPathComponent("parola-meetmic-AAA.wav")
            let orphan = folder.appendingPathComponent("parola-meetmic-BBB.wav")
            let youngOrphan = folder.appendingPathComponent("parola-meetmic-CCC.wav")

            let stale = AppModel.staleInflightFiles(
                in: [(take, now.addingTimeInterval(-60)), (paired, days), (orphan, days), (youngOrphan, now.addingTimeInterval(-3_600))],
                keeping: [],
                now: now
            )

            #expect(!stale.contains(paired), "two days old, but its take is still here")
            #expect(stale.contains(orphan))
            #expect(!stale.contains(youngOrphan), "an orphan goes only after two days")
            #expect(!stale.contains(take), "a take written a minute ago may still be recording")
        }

        @Test("a sweep at launch deletes only the two-day-old orphaned microphone track")
        func launchSweepDeletesOnlyOldOrphans() async throws {
            let library = makeTempLibraryURL("second-track-sweep")
            let folder = try inflight(library)
            let take = try makeTakeWAV("still-recording", seconds: 1, in: folder, prefix: "parola-system")
            let pairedName = RecordingScratch.meetingMicURL(for: take)
            try Data(count: 64 * 1024).write(to: pairedName)
            try age(pairedName, by: 3 * 86_400)
            let oldOrphan = try makeTakeWAV("old-orphan", in: folder, prefix: RecordingScratch.meetingMicPrefix)
            try age(oldOrphan, by: 3 * 86_400)
            let youngOrphan = try makeTakeWAV("young-orphan", in: folder, prefix: RecordingScratch.meetingMicPrefix)
            try age(youngOrphan, by: 3_600)

            let model = makeModel(libraryURL: library)
            await model.inflightSweep?.value

            #expect(FileManager.default.fileExists(atPath: pairedName.path), "kept with its take")
            #expect(!FileManager.default.fileExists(atPath: oldOrphan.path))
            #expect(FileManager.default.fileExists(atPath: youngOrphan.path))
            #expect(await model.library.list().isEmpty, "a microphone track is never imported as a take of its own")
        }

        @Test("a second instance leaves a running take's microphone track alone, whatever its name")
        func secondInstanceLeavesTheMicTrackAlone() async throws {
            let library = makeTempLibraryURL("second-track-two-instances")
            let folder = try inflight(library)
            let first = makeModel(libraryURL: library)
            await first.inflightSweep?.value
            let take = try makeTakeWAV("recording-elsewhere", seconds: 1, in: folder, prefix: "parola-system")
            let mic = try makeTakeWAV("mic-elsewhere", seconds: 1, in: folder, prefix: RecordingScratch.meetingMicPrefix)
            for file in [take, mic] { try age(file, by: 3 * 86_400) }
            first.beginRecordingRecovery()
            first.liveRecordingAudioURL = take
            first.liveCompanionAudioURL = mic
            first.writeRecordingCheckpoint()
            await first.pendingRecoveryWrite?.value

            let second = makeModel(libraryURL: library)
            await second.inflightSweep?.value

            #expect(FileManager.default.fileExists(atPath: take.path))
            #expect(FileManager.default.fileExists(atPath: mic.path), "its checkpoint names it, though nothing pairs it by name")
            first.endActiveRecovery()
        }

        @Test("Discard on the recovery offer deletes the meeting's microphone track with its take")
        func discardOfferDeletesTheMicTrack() async throws {
            let library = makeTempLibraryURL("second-track-discard-offer")
            let folder = try inflight(library)
            let take = try makeTakeWAV("crashed-meeting", in: folder, prefix: "parola-system")
            let mic = RecordingScratch.meetingMicURL(for: take)
            try FileManager.default.copyItem(at: take, to: mic)
            for file in [take, mic] { try age(file, by: 300) }
            try writeLegacyCheckpoint(RecoveryCheckpoint(
                kind: .recording, startedAt: Date(), modelName: "m", audioURL: take, source: .systemAudio, category: .meeting,
                companionAudioURL: mic
            ), library: library)
            let model = makeModel(libraryURL: library)
            #expect(model.pendingRecovery?.companionAudioURL == mic)
            #expect(model.inflightFileInUse(mic), "an offer still waiting holds its microphone track too")

            model.discardPendingRecovery()

            #expect(!FileManager.default.fileExists(atPath: take.path))
            #expect(!FileManager.default.fileExists(atPath: mic.path))
        }
    }
}
