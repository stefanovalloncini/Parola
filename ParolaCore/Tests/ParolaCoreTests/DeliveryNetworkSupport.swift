import Foundation
import os
@testable import ParolaCore

actor StubTransport: DeliveryHTTPTransport {
    private(set) var requests: [URLRequest] = []
    private var script: [Result<HTTPResult, any Error>]
    private let fallback: HTTPResult

    init(script: [Result<HTTPResult, any Error>] = [], fallback: HTTPResult = HTTPResult(status: 200)) {
        self.script = script
        self.fallback = fallback
    }

    func send(_ request: URLRequest) async throws -> HTTPResult {
        requests.append(request)
        guard !script.isEmpty else { return fallback }
        return try script.removeFirst().get()
    }

    func bodyText(at index: Int) -> String {
        String(decoding: requests[index].httpBody ?? Data(), as: UTF8.self)
    }
}

final class TrustLog: Sendable {
    private let lock = OSAllocatedUnfairLock(initialState: [TransportTrust]())

    func add(_ trust: TransportTrust) { lock.withLock { $0.append(trust) } }
    var values: [TransportTrust] { lock.withLock { $0 } }
}

enum NetworkTestRig {
    static func object(_ request: URLRequest) -> [String: Any] {
        let value = try? JSONSerialization.jsonObject(with: request.httpBody ?? Data())
        return value as? [String: Any] ?? [:]
    }

    static func environment(
        transport: StubTransport,
        secrets: InMemorySecretStore = InMemorySecretStore(),
        clock: any Clock<Duration> = ContinuousClock(),
        trustLog: TrustLog? = nil
    ) -> DeliveryEnvironment {
        DeliveryEnvironment(
            secrets: secrets,
            transport: { trust in
                trustLog?.add(trust)
                return transport
            },
            clock: clock
        )
    }

    static func json(_ object: Any, status: Int = 200, headers: [String: String] = [:]) -> HTTPResult {
        HTTPResult(status: status, headers: headers, body: (try? JSONSerialization.data(withJSONObject: object)) ?? Data())
    }

    static func manySegmentsPayload(paragraphs: Int) -> DeliveryPayload {
        var payload = DeliveryPayloadTests.payload()
        payload.summary = nil
        let alternating = (0..<paragraphs).map { index in
            TranscriptSegment(
                id: index, start: Double(index), end: Double(index) + 1,
                text: "Line \(index).", speaker: index.isMultiple(of: 2) ? "Ada" : "Grace"
            )
        }
        payload.transcript = Transcript(segments: alternating, language: "en", modelName: "m", durationSeconds: Double(paragraphs))
        return payload
    }
}
