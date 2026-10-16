import Foundation
import AppKit
import UniformTypeIdentifiers

protocol FilePicker: Sendable {
    func chooseInputFiles(allowedTypes: [UTType], allowsMultiple: Bool, message: String?) async -> [URL]
    func chooseSaveDestination(suggestedName: String, allowedTypes: [UTType], message: String?) async -> URL?
}

extension FilePicker {
    func chooseInputFiles(allowedTypes: [UTType], allowsMultiple: Bool) async -> [URL] {
        await chooseInputFiles(allowedTypes: allowedTypes, allowsMultiple: allowsMultiple, message: nil)
    }

    func chooseSaveDestination(suggestedName: String, allowedTypes: [UTType]) async -> URL? {
        await chooseSaveDestination(suggestedName: suggestedName, allowedTypes: allowedTypes, message: nil)
    }
}

@MainActor
final class SystemFilePicker: FilePicker {
    nonisolated init() {}

    func chooseInputFiles(allowedTypes: [UTType], allowsMultiple: Bool, message: String?) async -> [URL] {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = allowedTypes
        panel.allowsMultipleSelection = allowsMultiple
        if let message { panel.message = message }
        guard panel.runModal() == .OK else { return [] }
        return panel.urls
    }

    func chooseSaveDestination(suggestedName: String, allowedTypes: [UTType], message: String?) async -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = allowedTypes
        panel.nameFieldStringValue = suggestedName
        if let message { panel.message = message }
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }
}

final actor TestFilePicker: FilePicker {
    private var inputResponses: [[URL]] = []
    private var saveResponses: [URL?] = []
    private(set) var saveRequests: [SaveRequest] = []

    struct SaveRequest: Equatable, Sendable {
        let suggestedName: String
        let allowedTypes: [UTType]
    }

    func queueInputResponse(_ urls: [URL]) { inputResponses.append(urls) }
    func queueSaveResponse(_ url: URL?) { saveResponses.append(url) }

    func chooseInputFiles(allowedTypes: [UTType], allowsMultiple: Bool, message: String?) async -> [URL] {
        guard !inputResponses.isEmpty else { return [] }
        return inputResponses.removeFirst()
    }

    func chooseSaveDestination(suggestedName: String, allowedTypes: [UTType], message: String?) async -> URL? {
        saveRequests.append(SaveRequest(suggestedName: suggestedName, allowedTypes: allowedTypes))
        guard !saveResponses.isEmpty else { return nil }
        return saveResponses.removeFirst()
    }
}
