import AppKit
import Foundation
import ParolaCore
import UniformTypeIdentifiers

extension AppModel {
    static var diagnosticsDirectory: URL {
        DiagnosticsInstaller.current?.directory ?? DiagnosticsInstaller.defaultDirectory
    }

    /// nil means the save panel was dismissed; a thrown error means the report could not be written.
    @discardableResult
    func exportDiagnostics(directory: URL = AppModel.diagnosticsDirectory) async throws -> URL? {
        let stamp = Date().formatted(.iso8601.year().month().day().dateSeparator(.dash))
        guard let destination = await filePicker.chooseSaveDestination(
            suggestedName: "Parola-Diagnostics-\(stamp).txt",
            allowedTypes: [.plainText]
        ) else { return nil }
        let environment = await diagnosticsEnvironment()
        do {
            try await Self.offMainIO {
                let text = DiagnosticsExport.render(directory: directory, environment: environment)
                try text.write(to: destination, atomically: true, encoding: .utf8)
            }
        } catch {
            ParolaLog.error(.diagnostics, "diagnostics export failed", [.error: .error(error)])
            throw error
        }
        return destination
    }

    nonisolated static func diagnosticsExportFailureMessage(
        for error: any Error,
        bundle: Bundle = .main
    ) -> String {
        String(localized: "Couldn't export diagnostics: \(error.localizedDescription)", bundle: bundle)
    }

    func revealDiagnostics(directory: URL = AppModel.diagnosticsDirectory) async {
        try? await Self.offMainIO {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        NSWorkspace.shared.activateFileViewerSelecting([directory])
    }

    func deleteDiagnostics(directory: URL = AppModel.diagnosticsDirectory) async {
        await DiagnosticsInstaller.current?.startNewFile()
        try? await Self.offMainIO {
            for url in Self.diagnosticsFiles(in: directory) {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    func diagnosticsRecordsExist(directory: URL = AppModel.diagnosticsDirectory) async -> Bool {
        (try? await Self.offMainIO { !Self.diagnosticsFiles(in: directory).isEmpty }) ?? false
    }

    private nonisolated static func diagnosticsFiles(in directory: URL) -> [URL] {
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        )) ?? []
        return entries.filter {
            $0.lastPathComponent.hasPrefix(FileDiagnosticsSink.filePrefix) && $0.pathExtension == "jsonl"
        }
    }

    func diagnosticsEnvironment() async -> DiagnosticsEnvironment {
        let microphone = Self.diagnosticsPermission(
            authorized: dictationPermissions.microphoneAuthorized,
            undetermined: dictationPermissions.microphoneUndetermined
        )
        let screenRecording = Self.diagnosticsPermission(granted: capturePermissions.screenRecordingGranted)
        let systemAudio = Self.diagnosticsPermission(for: capturePermissions.systemAudioStatus)
        let accessibility = Self.diagnosticsPermission(granted: dictationPermissions.accessibilityGranted)

        await ParolaCoreBootstrap.registerBuiltInEngines()
        let engines = await Self.diagnosticsEngines(registry: .shared)

        let models = try? await Self.offMainIO {
            let store = ModelStore.shared
            return store.scan().installed.map { info in
                DiagnosticsEnvironment.InstalledModel(
                    token: ModelToken(info.name),
                    bytes: info.installedURL.flatMap { store.sizeOnDisk(at: $0) }.map(UInt64.init)
                )
            }
        }

        return DiagnosticsEnvironment(
            appVersion: AboutInfo.versionString,
            microphone: microphone,
            screenRecording: screenRecording,
            systemAudio: systemAudio,
            accessibility: accessibility,
            engines: engines,
            models: models ?? [],
            libraryEntryCount: await library.list().count,
            libraryBytes: await library.sizeOnDisk(),
            features: features
        )
    }

    static func diagnosticsEngines(registry: EngineRegistry) async -> [EngineID: Bool] {
        var engines: [EngineID: Bool] = [:]
        for id in [EngineID.whisperKit, .parakeet, .appleSpeech] {
            engines[id] = await registry.isRegistered(id)
        }
        return engines
    }

    static func diagnosticsPermission(
        authorized: Bool,
        undetermined: Bool
    ) -> DiagnosticsEnvironment.Permission {
        if authorized { return .granted }
        return undetermined ? .undetermined : .denied
    }

    /// A pending grant is indistinguishable from a refusal — the OS APIs here only answer yes or no.
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
