import Foundation

/// The app a take was dictated into, read where its capture ended.
public struct DictationTarget: Sendable, Equatable {
    public var processID: Int32
    public var bundleID: String?
    public var appName: String?
    public var url: URL?

    public init(processID: Int32, bundleID: String? = nil, appName: String? = nil, url: URL? = nil) {
        self.processID = processID
        self.bundleID = bundleID
        self.appName = appName
        self.url = url
    }
}

/// The cleanup and the insertion one take uses, built from its target.
public struct DictationTakeBinding: Sendable {
    public var postProcessor: any TextPostProcessor
    public var inserter: any TextInserter

    public init(postProcessor: any TextPostProcessor, inserter: any TextInserter) {
        self.postProcessor = postProcessor
        self.inserter = inserter
    }
}

public struct DictationPipelineConfiguration: Sendable {
    public var modelName: String?
    public var language: String?
    public var initialPrompt: String?
    public var deviceUID: String?
    public var streamingEnabled: Bool
    public var workflows: [String: [DictationWorkflow]]
    public var postProcessor: any TextPostProcessor
    public var pasteDelayMs: Int
    public var bind: (@Sendable (DictationTarget?) -> DictationTakeBinding)?

    public init(
        modelName: String? = nil,
        language: String? = nil,
        initialPrompt: String? = nil,
        deviceUID: String? = nil,
        streamingEnabled: Bool = true,
        workflows: [String: [DictationWorkflow]] = [:],
        postProcessor: any TextPostProcessor,
        pasteDelayMs: Int = 0,
        bind: (@Sendable (DictationTarget?) -> DictationTakeBinding)? = nil
    ) {
        self.modelName = modelName
        self.language = language
        self.initialPrompt = initialPrompt
        self.deviceUID = deviceUID
        self.streamingEnabled = streamingEnabled
        self.workflows = workflows
        self.postProcessor = postProcessor
        self.pasteDelayMs = pasteDelayMs
        self.bind = bind
    }
}
