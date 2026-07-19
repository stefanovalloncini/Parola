import Testing
@testable import ParolaCore

@Suite("System audio recording permission")
struct SystemAudioRecordingPermissionTests {
    @Test("preflight raw values map to statuses")
    func preflightMapping() {
        #expect(SystemAudioRecordingPermission.status(fromPreflight: 0) == .granted)
        #expect(SystemAudioRecordingPermission.status(fromPreflight: 2) == .denied)
        #expect(SystemAudioRecordingPermission.status(fromPreflight: 1) == .undetermined)
    }

    @Test("unrecognized raw values fall back to undetermined")
    func unknownRawValue() {
        #expect(SystemAudioRecordingPermission.status(fromPreflight: -1) == .undetermined)
        #expect(SystemAudioRecordingPermission.status(fromPreflight: 99) == .undetermined)
    }

    @Test("current returns a status without prompting")
    func currentReadsQuietly() {
        _ = SystemAudioRecordingPermission.current()
    }
}
