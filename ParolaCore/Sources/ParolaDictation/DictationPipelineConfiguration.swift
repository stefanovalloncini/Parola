import Foundation

public struct DictationPipelineConfiguration: Sendable {
    public var modelName: String?
    public var language: String?
    public var initialPrompt: String?
    public var deviceUID: String?
    public var streamingEnabled: Bool
    public var workflows: [String: [DictationWorkflow]]
    public var postProcessor: any TextPostProcessor
    public var pasteDelayMs: Int

    public init(
        modelName: String? = nil,
        language: String? = nil,
        initialPrompt: String? = nil,
        deviceUID: String? = nil,
        streamingEnabled: Bool = true,
        workflows: [String: [DictationWorkflow]] = [:],
        postProcessor: any TextPostProcessor,
        pasteDelayMs: Int = 0
    ) {
        self.modelName = modelName
        self.language = language
        self.initialPrompt = initialPrompt
        self.deviceUID = deviceUID
        self.streamingEnabled = streamingEnabled
        self.workflows = workflows
        self.postProcessor = postProcessor
        self.pasteDelayMs = pasteDelayMs
    }
}
