import Foundation
import SwiftUI
import ParolaCore

extension AppModel {
    func handleIncoming(url: URL) async {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        do {
            if url.pathExtension.lowercased() == "parola" {
                _ = try await library.adopt(parolaBundle: url)
                refreshLibrary()
            } else {
                let copy = TranscriptionCoordinator.importCopyURL(for: url)
                do {
                    try await FileCopier.copy(from: url, to: copy)
                } catch {
                    TranscriptionCoordinator.removeImportCopy(copy)
                    throw error
                }
                coordinator.startFileTranscriptionFromTrustedCopy(at: copy)
            }
        } catch {
            lastError = FailureText.message(for: error)
        }
    }
}
