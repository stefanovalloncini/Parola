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
                let copy = FileManager.default.temporaryDirectory
                    .appendingPathComponent("parola-incoming-\(UUID().uuidString)-\(url.lastPathComponent)")
                try await FileCopier.copy(from: url, to: copy)
                coordinator.startFileTranscriptionFromTrustedCopy(at: copy)
            }
        } catch {
            lastError = error.localizedDescription
        }
    }
}
