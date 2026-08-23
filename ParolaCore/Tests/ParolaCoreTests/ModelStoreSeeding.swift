import Foundation
import Testing
@testable import ParolaCore

extension ModelStore {
    /// Makes a variant read as installed. Creating the directory alone is not enough: a model
    /// directory with no weights in it reads as a half-finished download, and the caller under
    /// test then fetches the real model from the HuggingFace CDN.
    func seedInstalledModel(
        _ variant: String,
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws {
        let directory = installedURL(for: variant)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("weights".utf8).write(to: directory.appendingPathComponent("model.bin"))
        #expect(
            isInstalled(variant),
            "\(variant) must read as installed or the test downloads it for real",
            sourceLocation: sourceLocation
        )
    }
}
