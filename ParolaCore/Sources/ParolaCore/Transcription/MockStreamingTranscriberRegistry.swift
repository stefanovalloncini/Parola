import Foundation

public actor MockStreamingTranscriberRegistry {
    public static let shared = MockStreamingTranscriberRegistry()
    private var response: MockTranscriberResponse?
    public init() {}
    public func install(_ response: MockTranscriberResponse) { self.response = response }
    public func clear() { response = nil }
    public func resolve() -> MockTranscriberResponse? { response }
}
