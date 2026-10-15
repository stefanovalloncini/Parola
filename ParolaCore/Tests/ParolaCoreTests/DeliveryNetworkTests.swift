import Foundation
import Testing
@testable import ParolaCore
import ParolaTestSupport

@Suite("Network delivery destinations", .serialized)
struct DeliveryNetworkTests {

    // MARK: - Webhook

    private func webhook(
        url: String = "https://hooks.example.com/catch/1",
        headers: [WebhookHeader] = [],
        includeSegments: Bool = true,
        environment: DeliveryEnvironment
    ) -> WebhookDestination {
        WebhookDestination(
            name: "Zap", urlText: url, headers: headers, includeSegments: includeSegments, environment: environment
        )
    }

    @Test("a webhook posts versioned JSON with its secret header and the segments")
    func webhookPosts() async throws {
        let transport = StubTransport()
        let header = WebhookHeader(name: "X-Api-Key", secretRef: "ref-1")
        let environment = NetworkTestRig.environment(
            transport: transport, secrets: InMemorySecretStore(values: ["ref-1": "s3cret-value"])
        )
        let destination = webhook(headers: [header], environment: environment)

        let receipt = try await destination.deliver(ObsidianNoteRendererTests.payload())

        let request = try #require(await transport.requests.first)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.absoluteString == "https://hooks.example.com/catch/1")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(request.value(forHTTPHeaderField: "X-Api-Key") == "s3cret-value")
        #expect(request.timeoutInterval == 30)
        let body = NetworkTestRig.object(await transport.requests[0])
        #expect(body["parola"] as? Int == 1)
        #expect(body["id"] as? String == "entry-1")
        #expect(body["title"] as? String == "Interview")
        #expect(body["aiTitle"] as? String == "Release chat")
        #expect(body["language"] as? String == "en")
        #expect(body["category"] as? String == "meeting")
        #expect(body["duration"] as? Double == 134)
        #expect((body["createdAt"] as? String)?.hasSuffix("Z") == true)
        #expect(body["summary"] as? String == "Ada and Grace go over the export rewrite and what shipped.")
        #expect(body["actionItems"] as? [String] == ["Write the release note", "Ping the beta list"])
        let chapters = try #require(body["chapters"] as? [[String: Any]])
        #expect(chapters.map { $0["title"] as? String } == ["Welcome", "The rewrite"])
        #expect(chapters.map { $0["start"] as? Double } == [0, 74])
        let segments = try #require(body["segments"] as? [[String: Any]])
        #expect(segments.count == 3)
        #expect(segments[1]["speaker"] as? String == "Grace")
        #expect(segments[1]["start"] as? Double == 3.5)
        #expect((body["text"] as? String)?.hasPrefix("Welcome back to the show.") == true)
        #expect(receipt.destinationName == "Zap")
    }

    @Test("a webhook leaves the segments out when told to, and names the source app when known")
    func webhookWithoutSegments() async throws {
        let transport = StubTransport()
        let destination = webhook(includeSegments: false, environment: NetworkTestRig.environment(transport: transport))
        var payload = ObsidianNoteRendererTests.payload()
        payload.sourceAppBundleID = "us.zoom.xos"

        _ = try await destination.deliver(payload)

        let body = NetworkTestRig.object(await transport.requests[0])
        #expect(body["segments"] == nil)
        #expect(body["sourceApp"] as? String == "us.zoom.xos")
        #expect(body["text"] != nil)
    }

    @Test("the webhook URL rules", arguments: [
        ("https://hooks.zapier.com/hooks/catch/1/abc", true),
        ("https://example.com", true),
        ("http://localhost:5678/webhook", true),
        ("http://127.0.0.1:8080/x", true),
        ("http://[::1]:8080/x", true),
        ("http://192.168.1.20/hook", true),
        ("http://10.0.0.5/hook", true),
        ("http://172.16.4.1/hook", true),
        ("http://172.32.4.1/hook", false),
        ("http://nas.local/hook", true),
        ("http://nas/hook", true),
        ("http://example.com/hook", false),
        ("http://8.8.8.8/hook", false),
        ("ftp://example.com/hook", false),
        ("example.com/hook", false),
        ("", false),
    ])
    func urlRules(text: String, accepted: Bool) {
        let result = WebhookURLPolicy.validate(text)
        switch result {
        case .success: #expect(accepted, "\(text) should be refused")
        case .failure: #expect(!accepted, "\(text) should be accepted")
        }
    }

    @Test("an http address on the internet is refused with a plain sentence")
    func publicHttpSentence() {
        #expect(WebhookURLPolicy.validate("http://example.com") == .failure(.insecurePublicHost))
        #expect(WebhookURLError.insecurePublicHost.message.contains("https://"))
        #expect(WebhookURLPolicy.isUnencrypted(URL(string: "http://192.168.1.2")!))
        #expect(!WebhookURLPolicy.isUnencrypted(URL(string: "https://192.168.1.2")!))
    }

    @Test("a webhook delivery refuses an unsafe address before any request")
    func webhookRefusesBadAddress() async {
        let transport = StubTransport()
        let destination = webhook(url: "http://example.com/x", environment: NetworkTestRig.environment(transport: transport))
        await #expect(throws: DeliveryError.self) { try await destination.deliver(ObsidianNoteRendererTests.payload()) }
        #expect(await transport.requests.isEmpty)
    }

    @Test("a non-2xx answer is a failure that names the status and never the secret")
    func webhookFailureNamesStatus() async throws {
        let transport = StubTransport(script: [.success(HTTPResult(status: 503))])
        let header = WebhookHeader(name: "Authorization", secretRef: "ref-1")
        let environment = NetworkTestRig.environment(
            transport: transport, secrets: InMemorySecretStore(values: ["ref-1": "Bearer topsecret"])
        )
        let destination = webhook(headers: [header], environment: environment)

        do {
            _ = try await destination.deliver(ObsidianNoteRendererTests.payload())
            Issue.record("expected a failure")
        } catch let error as DeliveryError {
            #expect(error == .httpStatus("Zap", 503, ""))
            #expect(error.localizedDescription == "Zap answered HTTP 503.")
            #expect(!error.localizedDescription.contains("topsecret"))
        }
    }

    @Test("a transport error is a delivery failure that names the host")
    func webhookTransportError() async {
        let transport = StubTransport(script: [.failure(URLError(.notConnectedToInternet))])
        let destination = webhook(environment: NetworkTestRig.environment(transport: transport))
        do {
            _ = try await destination.deliver(ObsidianNoteRendererTests.payload())
            Issue.record("expected a failure")
        } catch let error as DeliveryError {
            guard case .networkFailed(let host, _) = error else {
                Issue.record("wrong error \(error)")
                return
            }
            #expect(host == "hooks.example.com")
        } catch {
            Issue.record("wrong error \(error)")
        }
    }

    @Test("Send Test returns the status whatever it is")
    func sendTestStatus() async throws {
        let transport = StubTransport(script: [.success(HTTPResult(status: 404)), .success(HTTPResult(status: 200))])
        let destination = webhook(environment: NetworkTestRig.environment(transport: transport))
        #expect(try await destination.sendTest(ObsidianNoteRendererTests.payload()) == 404)
        #expect(try await destination.sendTest(ObsidianNoteRendererTests.payload()) == 200)
    }

    // MARK: - Notion

    private func notion(environment: DeliveryEnvironment, secret: String = "ntn_secret") -> (NotionDestination, InMemorySecretStore) {
        let store = InMemorySecretStore(values: ["notion-ref": secret])
        var env = environment
        env.secrets = store
        return (NotionDestination(name: "Notes", parentPageID: "0123456789abcdef0123456789abcdef".asDashedID, secretRef: "notion-ref", environment: env), store)
    }

    @Test("Notion page IDs come out of links and bare IDs", arguments: [
        ("https://www.notion.so/My-Workspace/Meeting-notes-0123456789abcdef0123456789abcdef?pvs=4", "01234567-89ab-cdef-0123-456789abcdef"),
        ("https://www.notion.so/0123456789abcdef0123456789abcdef", "01234567-89ab-cdef-0123-456789abcdef"),
        ("0123456789ABCDEF0123456789ABCDEF", "01234567-89ab-cdef-0123-456789abcdef"),
        ("01234567-89ab-cdef-0123-456789abcdef", "01234567-89ab-cdef-0123-456789abcdef"),
        ("https://www.notion.so/team/Board-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa?v=1&p=0123456789abcdef0123456789abcdef", "01234567-89ab-cdef-0123-456789abcdef"),
    ])
    func pageIDs(text: String, expected: String) {
        #expect(NotionPageID.parse(text) == expected)
    }

    @Test("text that holds no page ID gives none", arguments: ["", "hello", "https://www.notion.so/Meeting-notes", "0123456789abcdef", "zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz"])
    func noPageID(text: String) {
        #expect(NotionPageID.parse(text) == nil)
    }

    @Test("blocks come in the order: summary, action items, chapters, transcript")
    func blockOrder() throws {
        var payload = ObsidianNoteRendererTests.payload()
        payload.summary = Summary(
            text: "First paragraph.\n\nSecond paragraph.",
            chapters: [Chapter(title: "Welcome", start: 0), Chapter(title: "Later", start: 3725)],
            actionItems: ["Write the note"]
        )
        let blocks = NotionBlocks.blocks(for: payload)
        let types = blocks.compactMap { $0.object?["type"]?.string }
        #expect(types == ["paragraph", "paragraph", "to_do", "bulleted_list_item", "bulleted_list_item", "heading_2", "paragraph", "paragraph", "paragraph"])
        let chapterText = Self.plainText(blocks[3])
        #expect(chapterText == "00:00 Welcome")
        #expect(Self.plainText(blocks[4]) == "1:02:05 Later")
        #expect(Self.plainText(blocks[5]) == "Transcript")
        let first = try #require(blocks[6].object?["paragraph"]?.object?["rich_text"])
        guard case .array(let runs) = first else { Issue.record("no runs"); return }
        #expect(runs.first?.object?["annotations"]?.object?["bold"] == .bool(true))
        #expect(runs.first?.object?["text"]?.object?["content"]?.string == "Ada ")
        #expect(runs.last?.object?["text"]?.object?["content"]?.string == "Welcome back to the show.")
    }

    @Test("an unlabelled transcript has no bold run, and consecutive speech joins into a paragraph")
    func unlabelledTranscript() {
        var payload = NetworkTestRig.manySegmentsPayload(paragraphs: 6)
        payload.transcript.segments = payload.transcript.segments.map { var copy = $0; copy.speaker = nil; return copy }
        let blocks = NotionBlocks.blocks(for: payload)
        #expect(blocks.count == 2)
        let text = Self.plainText(blocks[1])
        #expect(text == "Line 0. Line 1. Line 2. Line 3. Line 4. Line 5.")
        #expect(!String(describing: blocks[1]).contains("annotations"))
    }

    @Test("no run is longer than 2000 characters")
    func runLimit() {
        let long = String(repeating: "word ", count: 1000)
        let chunks = NotionBlocks.chunks(long)
        #expect(chunks.count == 3)
        #expect(chunks.allSatisfy { $0.utf16.count <= 2000 })
        #expect(chunks.joined(separator: " ").replacingOccurrences(of: "  ", with: " ").contains("word word"))

        let unbroken = String(repeating: "x", count: 4500)
        #expect(NotionBlocks.chunks(unbroken).map(\.count) == [2000, 2000, 500])
        let emoji = String(repeating: "😀", count: 1500)
        #expect(NotionBlocks.chunks(emoji).allSatisfy { $0.utf16.count <= 2000 })
        #expect(NotionBlocks.chunks("short") == ["short"])
        #expect(NotionBlocks.chunks("").isEmpty)
    }

    @Test("a long summary paragraph splits into runs of at most 2000 characters")
    func longParagraphRuns() {
        var payload = ObsidianNoteRendererTests.payload()
        payload.summary = Summary(text: String(repeating: "y", count: 4500))
        let blocks = NotionBlocks.blocks(for: payload)
        guard case .array(let runs)? = blocks[0].object?["paragraph"]?.object?["rich_text"] else {
            Issue.record("no runs")
            return
        }
        #expect(runs.compactMap { $0.object?["text"]?.object?["content"]?.string?.count } == [2000, 2000, 500])
    }

    @Test("a page is created with the first 100 blocks and the rest are appended in batches of 100")
    func notionBatches() async throws {
        let transport = StubTransport(script: [
            .success(NetworkTestRig.json(["id": "page-1", "url": "https://www.notion.so/page-1"])),
        ])
        let (destination, _) = notion(environment: NetworkTestRig.environment(transport: transport))
        var payload = NetworkTestRig.manySegmentsPayload(paragraphs: 251)
        payload.title = "Weekly sync"
        let total = NotionBlocks.blocks(for: payload).count
        #expect(total == 252)

        let receipt = try await destination.deliver(payload)

        let requests = await transport.requests
        #expect(requests.map(\.httpMethod) == ["POST", "PATCH", "PATCH"])
        #expect(requests.map { $0.url?.absoluteString } == [
            "https://api.notion.com/v1/pages",
            "https://api.notion.com/v1/blocks/page-1/children",
            "https://api.notion.com/v1/blocks/page-1/children",
        ])
        for request in requests {
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer ntn_secret")
            #expect(request.value(forHTTPHeaderField: "Notion-Version") == "2022-06-28")
            #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        }
        let created = NetworkTestRig.object(await transport.requests[0])
        #expect((created["children"] as? [Any])?.count == 100)
        let parent = created["parent"] as? [String: String]
        #expect(parent?["page_id"] == "01234567-89ab-cdef-0123-456789abcdef")
        let titleRuns = ((created["properties"] as? [String: Any])?["title"] as? [String: Any])?["title"] as? [[String: Any]]
        #expect((titleRuns?.first?["text"] as? [String: Any])?["content"] as? String == "Weekly sync")
        #expect((NetworkTestRig.object(await transport.requests[1])["children"] as? [Any])?.count == 100)
        #expect((NetworkTestRig.object(await transport.requests[2])["children"] as? [Any])?.count == 52)
        #expect(receipt.location?.absoluteString == "https://www.notion.so/page-1")
    }

    @Test("a 429 waits for Retry-After on the clock and tries again")
    func notionRateLimit() async throws {
        let clock = TestClock()
        let transport = StubTransport(script: [
            .success(HTTPResult(status: 429, headers: ["retry-after": "7"])),
            .success(NetworkTestRig.json(["id": "page-1"])),
        ])
        let (destination, _) = notion(environment: NetworkTestRig.environment(transport: transport, clock: clock))
        var payload = ObsidianNoteRendererTests.payload()
        payload.summary = nil

        let delivery = Task { try await destination.deliver(payload) }
        await clock.waitForSleeper()
        #expect(await transport.requests.count == 1)
        clock.advance(by: .seconds(6))
        #expect(await transport.requests.count == 1)
        clock.advance(by: .seconds(1))
        _ = try await delivery.value

        #expect(await transport.requests.count == 2)
    }

    @Test("a rate limit that never lifts becomes a failure after three waits")
    func notionRateLimitGivesUp() async {
        let clock = TestClock()
        let transport = StubTransport(fallback: HTTPResult(status: 429))
        let (destination, _) = notion(environment: NetworkTestRig.environment(transport: transport, clock: clock))
        var payload = ObsidianNoteRendererTests.payload()
        payload.summary = nil

        let delivery = Task { try await destination.deliver(payload) }
        for _ in 0..<3 {
            await clock.waitForSleeper()
            clock.advance(by: .seconds(1))
        }
        do {
            _ = try await delivery.value
            Issue.record("expected a failure")
        } catch {
            #expect((error as? DeliveryError) == .httpStatus("Notes", 429, ""))
        }
        #expect(await transport.requests.count == 4)
    }

    @Test("a failure partway leaves the page and reports how far it got")
    func notionPartial() async {
        let transport = StubTransport(script: [
            .success(NetworkTestRig.json(["id": "page-1"])),
            .success(HTTPResult(status: 500)),
        ])
        let (destination, _) = notion(environment: NetworkTestRig.environment(transport: transport))
        let payload = NetworkTestRig.manySegmentsPayload(paragraphs: 150)
        do {
            _ = try await destination.deliver(payload)
            Issue.record("expected a failure")
        } catch let error as DeliveryError {
            guard case .partialDelivery(_, let sent, let total, _) = error else {
                Issue.record("wrong error \(error)")
                return
            }
            #expect(sent == 100)
            #expect(total == 151)
        } catch {
            Issue.record("wrong error \(error)")
        }
        let methods = await transport.requests.map(\.httpMethod)
        #expect(methods == ["POST", "PATCH"], "nothing is deleted")
    }

    @Test("Check Connection says whether the page is shared")
    func notionCheck() async throws {
        let shared = NetworkTestRig.json(["properties": ["title": ["title": [["plain_text": "Meetings"]]]]])
        let transport = StubTransport(script: [
            .success(shared), .success(HTTPResult(status: 404)), .success(HTTPResult(status: 401)),
        ])
        let (destination, _) = notion(environment: NetworkTestRig.environment(transport: transport))
        #expect(try await destination.checkConnection() == .connected("Meetings"))
        #expect(try await destination.checkConnection() == .pageNotShared)
        #expect(try await destination.checkConnection() == .unauthorised)
        let first = try #require(await transport.requests.first)
        #expect(first.httpMethod == "GET")
        #expect(first.url?.absoluteString == "https://api.notion.com/v1/pages/01234567-89ab-cdef-0123-456789abcdef")
    }

    // MARK: - Obsidian Local REST

    private func rest(
        environment: DeliveryEnvironment,
        folder: String = "Parola Notes",
        base: String = "https://127.0.0.1:27124",
        collision: ObsidianCollisionPolicy = .overwrite
    ) -> ObsidianLocalRESTDestination {
        var env = environment
        env.secrets = InMemorySecretStore(values: ["rest-ref": "plugin-key"])
        return ObsidianLocalRESTDestination(
            name: "Vault", baseURLText: base, secretRef: "rest-ref", folder: folder, collision: collision, environment: env
        )
    }

    @Test("a note goes to PUT /vault/<folder>/<file>.md with the key and the rendered Markdown")
    func restPut() async throws {
        let transport = StubTransport(fallback: HTTPResult(status: 204))
        let destination = rest(environment: NetworkTestRig.environment(transport: transport))
        let payload = ObsidianNoteRendererTests.payload()

        _ = try await destination.deliver(payload)

        let request = try #require(await transport.requests.first)
        #expect(request.httpMethod == "PUT")
        #expect(request.url?.absoluteString == "https://127.0.0.1:27124/vault/Parola%20Notes/Interview.md")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer plugin-key")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "text/markdown")
        let expected = ObsidianNoteRenderer.render(payload, options: destination.noteOptions, title: "Interview")
        #expect(await transport.bodyText(at: 0) == expected)
    }

    @Test("a loopback https address asks for the self-signed trust and nothing else does")
    func restTrust() async throws {
        let transport = StubTransport(fallback: HTTPResult(status: 204))
        let log = TrustLog()
        let environment = NetworkTestRig.environment(transport: transport, trustLog: log)
        let loopback = rest(environment: environment)
        _ = try await loopback.deliver(ObsidianNoteRendererTests.payload())
        let remote = rest(environment: environment, base: "https://vault.example.com:27124")
        _ = try await remote.deliver(ObsidianNoteRendererTests.payload())
        #expect(log.values == [.loopbackSelfSigned, .system])
    }

    @Test("keep-both finds a free name by asking the plugin")
    func restCollision() async throws {
        let transport = StubTransport(script: [
            .success(HTTPResult(status: 200)), .success(HTTPResult(status: 200)), .success(HTTPResult(status: 404)),
            .success(HTTPResult(status: 204)),
        ])
        let destination = rest(environment: NetworkTestRig.environment(transport: transport), collision: .appendCounter)

        _ = try await destination.deliver(ObsidianNoteRendererTests.payload())

        let requests = await transport.requests
        #expect(requests.map(\.httpMethod) == ["GET", "GET", "GET", "PUT"])
        #expect(requests.last?.url?.lastPathComponent == "Interview 3.md")
    }

    @Test("the loopback certificate rule", arguments: [
        ("127.0.0.1", false, true), ("localhost", false, true), ("::1", false, true), ("[::1]", false, true),
        ("LOCALHOST", false, true),
        ("192.168.1.5", false, false), ("example.com", false, false), ("127.0.0.1.evil.com", false, false),
        ("notlocalhost", false, false),
        ("example.com", true, true), ("192.168.1.5", true, true),
    ])
    func loopbackRule(host: String, systemTrust: Bool, accepted: Bool) {
        #expect(LoopbackTrust.accepts(host: host, systemTrustPassed: systemTrust) == accepted)
    }

    @Test("Check Connection reports the plugin as reachable, or the key as refused")
    func restCheck() async throws {
        let transport = StubTransport(script: [
            .success(NetworkTestRig.json(["status": "OK", "authenticated": true])),
            .success(NetworkTestRig.json(["status": "OK", "authenticated": false])),
            .success(HTTPResult(status: 401)),
            .failure(URLError(.cannotConnectToHost)),
        ])
        let destination = rest(environment: NetworkTestRig.environment(transport: transport))
        #expect(try await destination.checkConnection() == .connected(nil))
        #expect(try await destination.checkConnection() == .unauthorised)
        #expect(try await destination.checkConnection() == .unauthorised)
        await #expect(throws: DeliveryError.self) { try await destination.checkConnection() }
        let first = try #require(await transport.requests.first)
        #expect(first.httpMethod == "GET")
        #expect(first.url?.absoluteString == "https://127.0.0.1:27124/")
        #expect(first.value(forHTTPHeaderField: "Authorization") == "Bearer plugin-key")
    }

    @Test("plain http is for this Mac and the local network only")
    func restHttpRules() async {
        let transport = StubTransport()
        let destination = rest(environment: NetworkTestRig.environment(transport: transport), base: "http://example.com:27123")
        await #expect(throws: DeliveryError.self) { try await destination.deliver(ObsidianNoteRendererTests.payload()) }
        #expect(await transport.requests.isEmpty)
        #expect(ObsidianLocalRESTDestination.validateBaseURL("http://127.0.0.1:27123/") == .success(URL(string: "http://127.0.0.1:27123")!))
    }

    // MARK: - Secrets and storage

    @Test("a destination with no saved secret fails before any request")
    func missingSecret() async {
        let transport = StubTransport()
        let destination = NotionDestination(
            name: "Notes", parentPageID: "01234567-89ab-cdef-0123-456789abcdef", secretRef: "nothing",
            environment: NetworkTestRig.environment(transport: transport)
        )
        await #expect(throws: DeliveryError.missingSecret("Notes")) { try await destination.deliver(ObsidianNoteRendererTests.payload()) }
        #expect(await transport.requests.isEmpty)
    }

    @Test("the encoded settings hold references and never a secret")
    func encodedHoldsNoSecret() async throws {
        let store = InMemorySecretStore()
        let header = WebhookHeader(name: "X-Key", secretRef: "hdr-ref")
        try await store.set("header-secret-value", for: "hdr-ref")
        try await store.set("notion-secret-value", for: "ntn-ref")
        try await store.set("rest-secret-value", for: "rest-ref")
        let list: [AnyDestination] = [
            .webhook(WebhookDestination(name: "Hook", urlText: "https://example.com/h", headers: [header])),
            .notion(NotionDestination(name: "Notion", parentPageID: "p", secretRef: "ntn-ref")),
            .obsidianREST(ObsidianLocalRESTDestination(name: "REST", secretRef: "rest-ref")),
        ]

        let json = String(decoding: try JSONEncoder().encode(list), as: UTF8.self)

        for secret in ["header-secret-value", "notion-secret-value", "rest-secret-value"] {
            #expect(!json.contains(secret))
        }
        for reference in ["hdr-ref", "ntn-ref", "rest-ref"] {
            #expect(json.contains(reference))
        }
        #expect(list.flatMap(\.secretRefs).sorted() == ["hdr-ref", "ntn-ref", "rest-ref"])
    }

    @Test("each kind encodes and decodes, and an unknown kind round-trips as unsupported")
    func codingRoundTrips() throws {
        let hook = WebhookDestination(
            name: "Hook", autoSend: true, categories: [.meeting], urlText: "https://example.com/h",
            headers: [WebhookHeader(name: "X-Key", secretRef: "r1")], includeSegments: false
        )
        let notion = NotionDestination(name: "N", titleFormat: .dateAndTitle, parentPageID: "01234567-89ab-cdef-0123-456789abcdef", secretRef: "r2")
        let restDestination = ObsidianLocalRESTDestination(name: "R", secretRef: "r3", folder: "A/B", collision: .overwrite, wikilinks: true)
        let unknown = AnyDestination.unsupported(kind: "carrierPigeon", config: .object(["id": .string("\(UUID())"), "coop": .string("north")]))
        let list: [AnyDestination] = [.webhook(hook), .notion(notion), .obsidianREST(restDestination), unknown]

        let decoded = try JSONDecoder().decode([AnyDestination].self, from: try JSONEncoder().encode(list))

        guard case .webhook(let hook2) = decoded[0], case .notion(let notion2) = decoded[1],
              case .obsidianREST(let rest2) = decoded[2], case .unsupported(let kind, let config) = decoded[3] else {
            Issue.record("kinds changed in the round trip: \(decoded)")
            return
        }
        #expect(hook2 == hook)
        #expect(notion2 == notion)
        #expect(rest2 == restDestination)
        #expect(kind == "carrierPigeon")
        #expect(config.object?["coop"]?.string == "north")
        #expect(decoded.map(\.kind) == [.webhook, .notion, .obsidianREST, nil])
        #expect(DestinationKind.allCases.allSatisfy { $0.isImplemented })
    }

    @Test("a config that cannot be read stays as an unsupported entry")
    func brokenConfigStaysUnsupported() {
        let decoded = DestinationRegistry.decode(kind: "notion", config: .object(["name": .string("no id")]))
        guard case .unsupported(let kind, _) = decoded else {
            Issue.record("expected unsupported")
            return
        }
        #expect(kind == "notion")
    }

    @Test("the secret store round-trips, falls back through an overlay, and deletes")
    func secretStores() async throws {
        let store = InMemorySecretStore()
        try await store.set("v1", for: "a")
        try await store.set("v2", for: "b")
        #expect(try await store.get("a") == "v1")
        let overlay = OverlaySecretStore(base: store, overrides: ["a": "typed", "c": "new"])
        #expect(try await overlay.get("a") == "typed")
        #expect(try await overlay.get("b") == "v2")
        #expect(try await overlay.get("c") == "new")
        #expect(try await store.get("c") == nil)

        await store.remove(["a", "b"])

        #expect(try await store.get("a") == nil)
        #expect(await store.references().isEmpty)
    }

    @Test("row settings change on any kind through one call")
    func updatingRowSettings() {
        let stored = AnyDestination.webhook(WebhookDestination(name: "Hook"))
        let changed = stored.updating(isEnabled: false, autoSend: true, categories: [.dictation], titleFormat: .aiTitle)
        #expect(!changed.isEnabled)
        #expect(changed.autoSend)
        #expect(changed.categories == [.dictation])
        #expect(changed.titleFormat == .aiTitle)
        #expect(changed.id == stored.id)
    }

    // MARK: - Engine

    @Test("a webhook that fails is queued by the engine and lands on the retry", .logFacade)
    func engineRetry() async throws {
        let transport = StubTransport(script: [.success(HTTPResult(status: 500)), .success(HTTPResult(status: 200))])
        let header = WebhookHeader(name: "X-Key", secretRef: "ref")
        let environment = NetworkTestRig.environment(
            transport: transport, secrets: InMemorySecretStore(values: ["ref": "engine-secret-value"])
        )
        let destination = AnyDestination.webhook(webhook(headers: [header], environment: environment))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("parola-net-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let engine = DeliveryEngine(
            destinations: { [destination] },
            payload: { id in
                var payload = ObsidianNoteRendererTests.payload()
                payload.entryID = id
                return payload
            },
            store: DeliveryQueueStore(directory: directory),
            clock: TestClock()
        )

        let first = await engine.send(entryID: "entry-1", to: destination.id)
        guard case .queued(let attempt, _) = first else {
            Issue.record("expected queued, got \(first)")
            return
        }
        #expect(attempt == 1)
        let second = await engine.send(entryID: "entry-1", to: destination.id)

        #expect(second.isDelivered)
        #expect(await transport.requests.count == 2)
        let log = await engine.recentLog()
        #expect(log.map(\.event) == [.queued, .delivered])
        #expect(log.first?.detail == "Zap answered HTTP 500.")
        let logText = String(decoding: try JSONEncoder().encode(log), as: UTF8.self)
        #expect(!logText.contains("engine-secret-value"))
    }

    // MARK: - Helpers

    private static func plainText(_ block: DestinationConfig) -> String {
        guard let type = block.object?["type"]?.string,
              case .array(let runs)? = block.object?[type]?.object?["rich_text"] else { return "" }
        return runs.compactMap { $0.object?["text"]?.object?["content"]?.string }.joined()
    }
}

private extension String {
    var asDashedID: String { NotionPageID.parse(self) ?? self }
}
