import AVFoundation
import Foundation
import Testing
@testable import Parola
import ParolaCore
import ParolaTestSupport

@MainActor
@Suite("Permission and bridge logging", .serialized)
struct PermissionLoggingTests {
    private func withSink(_ body: (CapturingDiagnosticsSink) async throws -> Void) async rethrows {
        let sink = CapturingDiagnosticsSink()
        try await ParolaLog.withSink(sink) { try await body(sink) }
    }

    private func records(
        _ sink: CapturingDiagnosticsSink, _ category: LogCategory, message: String
    ) -> [LogRecord] {
        sink.records.filter { $0.category == category && $0.message.rendered == message }
    }

    private func appSource(_ name: String) throws -> String {
        let path = #filePath.replacingOccurrences(
            of: "ParolaAppTests/PermissionLoggingTests.swift",
            with: "ParolaApp/\(name).swift"
        )
        let source = try String(contentsOfFile: path, encoding: .utf8)
        return source.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    @Test("screen recording and system audio are logged when they change, once per change")
    func captureStateChanges() async {
        await withSink { sink in
            let screen = Box(false)
            let audio = Box(SystemAudioRecordingPermission.denied)
            let permissions = SystemCapturePermissions(
                screenCheck: { screen.value },
                screenRequest: { false },
                audioCheck: { audio.value },
                consentProbe: {},
                openSettingsPane: { _ in }
            )

            permissions.refresh()
            #expect(records(sink, .appPermissions, message: "screen recording permission denied").isEmpty)

            screen.value = true
            audio.value = .granted
            permissions.refresh()
            permissions.refresh()

            let screenRecords = records(sink, .appPermissions, message: "screen recording permission granted")
            #expect(screenRecords.count == 1)
            #expect(screenRecords.first?.level == .notice)
            #expect(records(sink, .appPermissions, message: "system audio permission granted").count == 1)
        }
    }

    @Test("accessibility and microphone are logged when they change, once per change")
    func dictationStateChanges() async {
        await withSink { sink in
            let trusted = Box(false)
            let microphone = Box(AVAuthorizationStatus.notDetermined)
            let permissions = DictationPermissions(
                trustCheck: { trusted.value },
                microphoneStatus: { microphone.value }
            )

            permissions.refresh()
            permissions.refresh()
            #expect(sink.records.filter { $0.category == .appPermissions }.isEmpty)

            trusted.value = true
            microphone.value = .denied
            permissions.refresh()
            permissions.refresh()

            #expect(records(sink, .appPermissions, message: "accessibility permission granted").count == 1)
            let mic = records(sink, .appPermissions, message: "microphone permission denied")
            #expect(mic.count == 1)
            #expect(mic.first?.level == .notice)
        }
    }

    @Test("a command with the wrong token is logged without the command or the token")
    func bridgeRejectsBadToken() async throws {
        try await withSink { sink in
            let model = AppModel(
                skipBootstrap: true,
                defaults: temporaryDefaults("permission-logging-"),
                libraryURL: makeTempLibraryURL("permission-logging")
            )
            let server = try ParolaAutomationServer(model: model)
            let line = Data(#"{"id":"1","cmd":"getState","auth":"not-the-token"}"#.utf8)

            _ = await server.handle(line: line)

            let found = records(sink, .appBridge, message: "bridge rejected a command with a bad token")
            #expect(found.count == 1)
            let record = try #require(found.first)
            #expect(record.level == .notice)
            #expect(record.formattedLine.contains("getState") == false)
            #expect(record.formattedLine.contains("not-the-token") == false)
            withExtendedLifetime(server) {}
        }
    }

    /// No command handler throws anything but an `AutomationError`, so the catch-all is pinned in
    /// source until one does.
    @Test("the bridge's unmapped-error site logs the error kind, never the error text")
    func bridgeUnmappedErrorSite() throws {
        let source = try appSource("Bridge/ParolaAutomationServer")
        #expect(source.contains(
            #"ParolaLog.error(.appBridge, "bridge command threw an unmapped error", [.error: .error(error)])"#
        ))
    }

    @Test("a bridge server that cannot be created is logged instead of silently not starting")
    func bridgeCreationFailureSite() throws {
        let source = try appSource("AppModel")
        #expect(source.contains(
            #"} catch { ParolaLog.error(.appBridge, "bridge server could not be created", [.error: .error(error)]) return }"#
        ))
    }
}

/// A settable box so a permission stub can answer differently between refreshes.
@MainActor
private final class Box<Value> {
    var value: Value
    init(_ value: Value) { self.value = value }
}
