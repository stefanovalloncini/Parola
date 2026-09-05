import AppKit
import Foundation
import ParolaCore
import UniformTypeIdentifiers

extension AppModel {
    static var diagnosticsDirectory: URL {
        DiagnosticsInstaller.current?.directory ?? DiagnosticsInstaller.defaultDirectory
    }

    @discardableResult
    func exportDiagnostics(directory: URL = AppModel.diagnosticsDirectory) async -> URL? {
        let stamp = Date().formatted(.iso8601.year().month().day().dateSeparator(.dash))
        guard let destination = await filePicker.chooseSaveDestination(
            suggestedName: "Parola-Diagnostics-\(stamp).txt",
            allowedTypes: [.plainText]
        ) else { return nil }
        let environment = await diagnosticsEnvironment()
        let text = await Task.detached(priority: .userInitiated) {
            DiagnosticsExport.render(directory: directory, environment: environment)
        }.value
        do {
            try text.write(to: destination, atomically: true, encoding: .utf8)
        } catch {
            ParolaLog.error(.export, "diagnostics export failed", [.error: .error(error)])
            return nil
        }
        return destination
    }

    func revealDiagnostics(directory: URL = AppModel.diagnosticsDirectory) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([directory])
    }

    func deleteDiagnostics(directory: URL = AppModel.diagnosticsDirectory) async {
        await DiagnosticsInstaller.current?.startNewFile()
        let manager = FileManager.default
        let entries = (try? manager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        )) ?? []
        for url in entries where url.pathExtension == "jsonl" {
            try? manager.removeItem(at: url)
        }
    }

    func diagnosticsRecordsExist(directory: URL = AppModel.diagnosticsDirectory) -> Bool {
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        )) ?? []
        return entries.contains { $0.pathExtension == "jsonl" }
    }

    func diagnosticsEnvironment() async -> DiagnosticsEnvironment {
        let microphone = Self.diagnosticsPermission(
            authorized: dictationPermissions.microphoneAuthorized,
            undetermined: dictationPermissions.microphoneUndetermined
        )
        let screenRecording = Self.diagnosticsPermission(granted: capturePermissions.screenRecordingGranted)
        let systemAudio = Self.diagnosticsPermission(for: capturePermissions.systemAudioStatus)
        let accessibility = Self.diagnosticsPermission(granted: dictationPermissions.accessibilityGranted)

        let registry = EngineRegistry.shared
        await ParolaCoreBootstrap.registerBuiltInEngines(registry: registry)
        var engines: [EngineID: Bool] = [:]
        for id in [EngineID.whisperKit, .parakeet, .appleSpeech] {
            engines[id] = await registry.isRegistered(id)
        }

        let models = await Task.detached(priority: .userInitiated) {
            let store = ModelStore.shared
            return store.scan().installed.map { info in
                DiagnosticsEnvironment.InstalledModel(
                    token: ModelToken(info.name),
                    bytes: info.installedURL.flatMap { store.sizeOnDisk(at: $0) }.map(UInt64.init)
                )
            }
        }.value

        return DiagnosticsEnvironment(
            appVersion: AboutInfo.versionString,
            microphone: microphone,
            screenRecording: screenRecording,
            systemAudio: systemAudio,
            accessibility: accessibility,
            engines: engines,
            models: models,
            libraryEntryCount: await library.list().count,
            libraryBytes: await library.sizeOnDisk(),
            features: features
        )
    }

    static func diagnosticsPermission(
        authorized: Bool,
        undetermined: Bool
    ) -> DiagnosticsEnvironment.Permission {
        if authorized { return .granted }
        return undetermined ? .undetermined : .denied
    }

    /// `CGPreflightScreenCaptureAccess` and `AXIsProcessTrusted` answer yes or no, so a pending
    /// grant is indistinguishable from a refusal here.
    static func diagnosticsPermission(granted: Bool) -> DiagnosticsEnvironment.Permission {
        granted ? .granted : .denied
    }

    static func diagnosticsPermission(
        for status: SystemAudioRecordingPermission
    ) -> DiagnosticsEnvironment.Permission {
        switch status {
        case .granted: return .granted
        case .undetermined: return .undetermined
        case .denied: return .denied
        }
    }
}
