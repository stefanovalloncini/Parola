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
        ("http://134744072/hook", false),
        ("http://0x08080808/hook", false),
        ("http://0x8.8.8.8/hook", false),
        ("http://010.0.0.1/hook", false),
        ("http://127.1/hook", true),
        ("http://169.254.10.1/hook", true),
        ("http://[fe80::1]/hook", true),
        ("http://[febf::1]/hook", true),
        ("http://[fe90::1]/hook", true),
        ("http://[fec0::1]/hook", false),
        ("http://[fd12:3456::1]/hook", true),
        ("http://[fc00::1]/hook", true),
        ("http://[fc::1]/hook", false),
        ("http://[2001:db8::1]/hook", false),
        ("http://[::ffff:127.0.0.1]/hook", false),
        ("http://nas.lan/hook", true),
        ("http://box.home.arpa/hook", true),
        ("http://123/hook", false),
        ("http://99999999999/hook", false),
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

    @Test("each present section opens with a heading, in the order summary, action items, chapters, transcript")
    func blockOrder() throws {
        var payload = ObsidianNoteRendererTests.payload()
        payload.summary = Summary(
            text: "First paragraph.\n\nSecond paragraph.",
            chapters: [Chapter(title: "Welcome", start: 0), Chapter(title: "Later", start: 3725)],
            actionItems: ["Write the note"]
        )
        let blocks = NotionBlocks.blocks(for: payload)
        let types = blocks.compactMap { $0.object?["type"]?.string }
        #expect(types == [
            "heading_2", "paragraph", "paragraph",
            "heading_2", "to_do",
            "heading_2", "bulleted_list_item", "bulleted_list_item",
            "heading_2", "paragraph", "paragraph", "paragraph",
        ])
        #expect([0, 3, 5, 8].map { Self.plainText(blocks[$0]) } == ["Summary", "Action Items", "Chapters", "Transcript"])
        #expect(Self.plainText(blocks[6]) == "00:00 Welcome")
        #expect(Self.plainText(blocks[7]) == "1:02:05 Later")
        let first = try #require(blocks[9].object?["paragraph"]?.object?["rich_text"])
        guard case .array(let runs) = first else { Issue.record("no runs"); return }
        #expect(runs.first?.object?["annotations"]?.object?["bold"] == .bool(true))
        #expect(runs.first?.object?["text"]?.object?["content"]?.string == "Ada ")
        #expect(runs.last?.object?["text"]?.object?["content"]?.string == "Welcome back to the show.")
    }

    @Test("a section with nothing in it gets no heading, and the headings come from the environment")
    func headingsAreOptionalAndLocalised() {
        var payload = ObsidianNoteRendererTests.payload()
        payload.summary = Summary(text: "Only a summary.")
        let headings = NotionHeadings(summary: "Riepilogo", actionItems: "Azioni", chapters: "Capitoli", transcript: "Trascrizione")
        let blocks = NotionBlocks.blocks(for: payload, headings: headings)
        let headingTexts = blocks.filter { $0.object?["type"]?.string == "heading_2" }.map(Self.plainText)
        #expect(headingTexts == ["Riepilogo", "Trascrizione"])
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

    @Test("no run is longer than 2000 characters and the runs join back into the text")
    func runLimit() {
        let long = (0..<1500).map { "word\($0)" }.joined(separator: " ")
        let chunks = NotionBlocks.chunks(long)
        #expect(chunks.count > 3)
        #expect(chunks.allSatisfy { $0.utf16.count <= 2000 })
        #expect(chunks.joined() == long)
        #expect(chunks.dropLast().allSatisfy { $0.hasSuffix(" ") }, "cut after a space, not in the middle of a word")

        let unbroken = String(repeating: "x", count: 4500)
        #expect(NotionBlocks.chunks(unbroken).map(\.count) == [2000, 2000, 500])
        #expect(NotionBlocks.chunks(unbroken).joined() == unbroken)
        let mixed = String(repeating: "ab ", count: 300) + String(repeating: "y", count: 2500) + " end"
        #expect(NotionBlocks.chunks(mixed).joined() == mixed)
        #expect(NotionBlocks.chunks(mixed).allSatisfy { $0.utf16.count <= 2000 })
        #expect(NotionBlocks.chunks("short") == ["short"])
        #expect(NotionBlocks.chunks("").isEmpty)
    }

    @Test("a cut never falls inside a character", arguments: [
        String(repeating: "😀", count: 1500),
        String(repeating: "👩‍👩‍👧‍👦", count: 400),
        String(repeating: "e\u{301}", count: 1500),
        String(repeating: "👩‍👩‍👧‍👦 ", count: 300),
    ])
    func graphemeSafeCuts(text: String) {
        let chunks = NotionBlocks.chunks(text)
        #expect(chunks.count > 1)
        #expect(chunks.allSatisfy { $0.utf16.count <= 2000 && !$0.isEmpty })
        #expect(chunks.joined() == text)
        #expect(Array(chunks.joined()) == chunks.flatMap { Array($0) }, "every boundary is a character boundary")
    }

    @Test("one character longer than the limit is split by scalar without an empty run")
    func giantGrapheme() {
        let giant = "e" + String(repeating: "\u{301}", count: 2100)
        for text in ["start " + giant, giant, giant + " end"] {
            let chunks = NotionBlocks.chunks(text)
            #expect(chunks.allSatisfy { $0.utf16.count <= 2000 && !$0.isEmpty })
            #expect(chunks.joined() == text)
        }
    }

    @Test("a long summary paragraph splits into runs of at most 2000 characters")
    func longParagraphRuns() {
        var payload = ObsidianNoteRendererTests.payload()
        payload.summary = Summary(text: String(repeating: "y", count: 4500))
        let blocks = NotionBlocks.blocks(for: payload)
        guard case .array(let runs)? = blocks[1].object?["paragraph"]?.object?["rich_text"] else {
            Issue.record("no runs")
            return
        }
        #expect(runs.compactMap { $0.object?["text"]?.object?["content"]?.string?.count } == [2000, 2000, 500])
    }

    @Test("a block holds at most 50 runs, and a longer paragraph carries on in another block")
    func runsPerBlock() {
        var payload = ObsidianNoteRendererTests.payload()
        payload.summary = Summary(text: String(repeating: "y", count: 2000 * 120))
        let paragraphs = NotionBlocks.blocks(for: payload).filter { $0.object?["type"]?.string == "paragraph" }
        let counts = paragraphs.compactMap { block -> Int? in
            guard case .array(let runs)? = block.object?["paragraph"]?.object?["rich_text"] else { return nil }
            return runs.count
        }
        #expect(Array(counts.prefix(3)) == [50, 50, 20])
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

    @Test("a 429 waits exactly the Retry-After seconds on the clock and then tries again")
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
        #expect(clock.sleeperCount == 1, "still waiting after 6 of 7 seconds")
        clock.advance(by: .seconds(1))
        _ = try await delivery.value

        #expect(await transport.requests.count == 2)
    }

    @Test("the Retry-After wait", arguments: [
        ("7", 7.0), ("0", 1.0), ("600", 60.0), ("2.5", 2.5), ("soon", 1.0), ("-3", 1.0), ("-1", 1.0),
        ("nan", 1.0), ("NaN", 1.0), ("inf", 1.0), ("-inf", 1.0), ("1e400", 1.0),
    ])
    func retryAfterSeconds(header: String, expected: Double) {
        let result = HTTPResult(status: 429, headers: ["retry-after": header])
        #expect(NotionDestination.retryDelay(result) == expected)
        #expect(NotionDestination.retryDelay(HTTPResult(status: 429)) == 1)
    }

    @Test("Retry-After as an HTTP date counts from now")
    func retryAfterDate() {
        let now = Date(timeIntervalSince1970: 1_792_000_000)
        let later = now.addingTimeInterval(20)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        let result = HTTPResult(status: 429, headers: ["retry-after": formatter.string(from: later)])
        #expect(NotionDestination.retryDelay(result, now: now) == 20)
        let far = HTTPResult(status: 429, headers: ["retry-after": formatter.string(from: now.addingTimeInterval(9000))])
        #expect(NotionDestination.retryDelay(far, now: now) == 60)
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
            guard case .partialDelivery(_, let sent, let total, let underlying, let resume) = error else {
                Issue.record("wrong error \(error)")
                return
            }
            #expect(sent == 100)
            #expect(total == 151)
            #expect(underlying == .httpStatus("Notes", 500, ""))
            #expect(resume.hasPrefix("page-1|100|"))
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

    // MARK: - Trust, redirects and secrets

    @Test("the certificate decision follows the session, the challenge kind and the host", arguments: [
        (TransportTrust.loopbackSelfSigned, NSURLAuthenticationMethodServerTrust, "127.0.0.1", false, LoopbackTrust.Decision.acceptCertificate),
        (.loopbackSelfSigned, NSURLAuthenticationMethodServerTrust, "localhost", false, .acceptCertificate),
        (.loopbackSelfSigned, NSURLAuthenticationMethodServerTrust, "::1", false, .acceptCertificate),
        (.loopbackSelfSigned, NSURLAuthenticationMethodServerTrust, "192.168.1.5", false, .defaultHandling),
        (.loopbackSelfSigned, NSURLAuthenticationMethodServerTrust, "example.com", false, .defaultHandling),
        (.loopbackSelfSigned, NSURLAuthenticationMethodServerTrust, "example.com", true, .defaultHandling),
        (.loopbackSelfSigned, NSURLAuthenticationMethodClientCertificate, "127.0.0.1", false, .defaultHandling),
        (.loopbackSelfSigned, NSURLAuthenticationMethodHTTPBasic, "127.0.0.1", true, .defaultHandling),
        (.system, NSURLAuthenticationMethodServerTrust, "127.0.0.1", false, .defaultHandling),
        (.system, NSURLAuthenticationMethodServerTrust, "localhost", false, .defaultHandling),
    ])
    func trustDecision(trust: TransportTrust, method: String, host: String, systemTrust: Bool, expected: LoopbackTrust.Decision) {
        #expect(LoopbackTrust.decision(trust: trust, authenticationMethod: method, host: host, systemTrustPassed: systemTrust) == expected)
    }

    @Test("the session delegate refuses a cross-origin redirect and follows a same-origin one", arguments: [
        (TransportTrust.system, "https://hooks.example.com/a", "https://other.example.com/a", false),
        (.loopbackSelfSigned, "https://127.0.0.1:9/a", "https://localhost:9/a", false),
        (.system, "https://hooks.example.com/a", "https://hooks.example.com/b", true),
        (.system, "https://hooks.example.com/a", "https://hooks.example.com:443/b", true),
    ])
    func delegateRedirects(trust: TransportTrust, from: String, to: String, followed: Bool) async throws {
        let delegate = DeliverySessionDelegate(trust: trust)
        let fromURL = try #require(URL(string: from))
        let toURL = try #require(URL(string: to))
        let task = URLSession.shared.dataTask(with: fromURL)
        let response = try #require(HTTPURLResponse(url: fromURL, statusCode: 307, httpVersion: nil, headerFields: nil))
        let target = URLRequest(url: toURL)

        let result = await delegate.urlSession(URLSession.shared, task: task, willPerformHTTPRedirection: response, newRequest: target)

        #expect((result != nil) == followed)
        task.cancel()
    }

    @Test("a redirect is followed only to the same scheme, host and port", arguments: [
        ("https://hooks.example.com/a", "https://hooks.example.com/b", true),
        ("https://hooks.example.com/a", "https://HOOKS.example.com/b", true),
        ("https://hooks.example.com/a", "https://other.example.com/a", false),
        ("https://hooks.example.com/a", "http://hooks.example.com/a", false),
        ("https://hooks.example.com/a", "https://hooks.example.com:8443/a", false),
        ("http://127.0.0.1:9/a", "http://localhost:9/a", false),
        ("https://hooks.example.com/", "https://hooks.example.com:443/x", true),
        ("http://hooks.example.com/", "http://hooks.example.com:80/x", true),
        ("https://hooks.example.com:443/", "https://hooks.example.com/x", true),
        ("https://hooks.example.com/", "https://hooks.example.com:8443/x", false),
        ("http://hooks.example.com/", "https://hooks.example.com:80/x", false),
    ])
    func redirects(from: String, to: String, allowed: Bool) {
        #expect(RedirectPolicy.allows(from: URL(string: from), to: URL(string: to)) == allowed)
        #expect(!RedirectPolicy.allows(from: nil, to: URL(string: to)))
    }

    @Test("a header whose value is gone stops the delivery before any request")
    func headerWithoutValue() async {
        let transport = StubTransport()
        let header = WebhookHeader(name: "X-Key", secretRef: "gone")
        let destination = webhook(headers: [header], environment: NetworkTestRig.environment(transport: transport))
        await #expect(throws: DeliveryError.missingSecret("Zap")) { try await destination.deliver(ObsidianNoteRendererTests.payload()) }
        #expect(await transport.requests.isEmpty)
    }

    @Test("a transport failure never carries a header value, in the error or in the engine log", .logFacade)
    func transportFailureKeepsSecretsOut() async throws {
        let transport = StubTransport(script: [.failure(URLError(.cannotConnectToHost))])
        let header = WebhookHeader(name: "Authorization", secretRef: "ref")
        let environment = NetworkTestRig.environment(
            transport: transport, secrets: InMemorySecretStore(values: ["ref": "Bearer leak-canary"])
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

        let outcome = await engine.send(entryID: "entry-1", to: destination.id)

        #expect(outcome.queuedDate != nil)
        let error = DeliveryError.networkFailed("hooks.example.com", NetworkFailure(URLError(.cannotConnectToHost)))
        #expect(!error.localizedDescription.contains("leak-canary"))
        let log = String(decoding: try JSONEncoder().encode(await engine.recentLog()), as: UTF8.self)
        #expect(!log.contains("leak-canary"))
        #expect(log.contains("The server refused the connection."))
    }

    @Test("URL errors map to the failure the app words", arguments: [
        (URLError.Code.notConnectedToInternet, NetworkFailure.offline),
        (.timedOut, .timedOut),
        (.cannotConnectToHost, .cannotConnect),
        (.networkConnectionLost, .cannotConnect),
        (.cannotFindHost, .hostNotFound),
        (.dnsLookupFailed, .hostNotFound),
        (.secureConnectionFailed, .tlsFailed),
        (.serverCertificateUntrusted, .tlsFailed),
        (.cancelled, .cancelled),
        (.badURL, .other),
    ])
    func networkFailureMapping(code: URLError.Code, expected: NetworkFailure) {
        #expect(NetworkFailure(URLError(code)) == expected)
    }

    // MARK: - Permanent failures and resume

    @Test("which failures are permanent", arguments: [
        (DeliveryError.httpStatus("Z", 400, ""), true), (.httpStatus("Z", 401, ""), true), (.httpStatus("Z", 403, ""), true),
        (.httpStatus("Z", 404, ""), true), (.httpStatus("Z", 410, ""), true), (.httpStatus("Z", 422, ""), true),
        (.httpStatus("Z", 307, ""), true), (.redirected("Z", status: 307), true), (.pageNotReturned("Notes"), true),
        (.httpStatus("Z", 408, ""), false), (.httpStatus("Z", 429, ""), false), (.httpStatus("Z", 500, ""), false),
        (.httpStatus("Z", 503, ""), false),
        (.networkFailed("h", .timedOut), false), (.writeFailed("p", "r"), false),
        (.invalidSetup("Z", .notionPage), true), (.invalidSetup("Z", .address(.empty)), true), (.missingSecret("Z"), true),
        (.partialDelivery("Z", sent: 1, total: 2, underlying: .httpStatus("Z", 401, ""), resume: "r"), true),
        (.partialDelivery("Z", sent: 1, total: 2, underlying: .httpStatus("Z", 500, ""), resume: "r"), false),
    ])
    func permanence(error: DeliveryError, permanent: Bool) {
        #expect(error.isPermanent == permanent)
    }

    private func engine(
        for destination: AnyDestination, clock: TestClock = TestClock(), directory: URL
    ) -> DeliveryEngine {
        DeliveryEngine(
            destinations: { [destination] },
            payload: { id in
                var payload = ObsidianNoteRendererTests.payload()
                payload.entryID = id
                return payload
            },
            store: DeliveryQueueStore(directory: directory),
            clock: clock
        )
    }

    private func tempDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("parola-net-\(UUID())", isDirectory: true)
    }

    @Test("a refusal the server will repeat is dropped with its reason, not queued", .logFacade)
    func permanentFailureIsNotRetried() async throws {
        let transport = StubTransport(script: [.success(HTTPResult(status: 401))])
        let destination = AnyDestination.webhook(webhook(environment: NetworkTestRig.environment(transport: transport)))
        let directory = tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let engine = engine(for: destination, directory: directory)

        let outcome = await engine.send(entryID: "entry-1", to: destination.id)

        #expect(outcome == .skipped(reason: .rejected("Zap", .httpStatus("Zap", 401, ""))))
        #expect(await engine.pending().isEmpty)
        #expect(await engine.recentLog().map(\.event) == [.dropped])
        #expect(DeliverySkipReason.rejected("Zap", .httpStatus("Zap", 401, "")).message == "Zap answered HTTP 401.")
    }

    @Test("a transient failure is queued", .logFacade, arguments: [408, 429, 500, 503])
    func transientFailureIsQueued(status: Int) async throws {
        let transport = StubTransport(script: [.success(HTTPResult(status: status))])
        let destination = AnyDestination.webhook(webhook(environment: NetworkTestRig.environment(transport: transport)))
        let directory = tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let engine = engine(for: destination, directory: directory)

        let outcome = await engine.send(entryID: "entry-1", to: destination.id)

        guard case .queued = outcome else {
            Issue.record("expected queued, got \(outcome)")
            return
        }
        #expect(await engine.pending().count == 1)
    }

    private func notionEngine(
        transport: any DeliveryHTTPTransport, directory: URL, paragraphs: Int = 150
    ) -> (DeliveryEngine, AnyDestination) {
        let (destination, _) = notion(environment: DeliveryEnvironment(
            secrets: InMemorySecretStore(), transport: { _ in transport }
        ))
        let stored = AnyDestination.notion(destination)
        let engine = DeliveryEngine(
            destinations: { [stored] },
            payload: { id in
                var payload = NetworkTestRig.manySegmentsPayload(paragraphs: paragraphs)
                payload.entryID = id
                return payload
            },
            store: DeliveryQueueStore(directory: directory),
            clock: TestClock()
        )
        return (engine, stored)
    }

    @Test("a retry carries on with the same Notion page instead of making another", .logFacade)
    func notionResumes() async throws {
        let transport = StubTransport(script: [
            .success(NetworkTestRig.json(["id": "page-1", "url": "https://www.notion.so/page-1"])),
            .success(HTTPResult(status: 500)),
            .success(HTTPResult(status: 200)),
        ])
        let directory = tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (engine, stored) = notionEngine(transport: transport, directory: directory)

        let first = await engine.send(entryID: "entry-1", to: stored.id)
        guard case .queued = first else {
            Issue.record("expected queued, got \(first)")
            return
        }
        let queued = try #require(await engine.pending().first)
        #expect(queued.resume?.hasPrefix("page-1|100|") == true)

        let second = await engine.send(entryID: "entry-1", to: stored.id)

        let receipt = try #require(second.receipt)
        #expect(receipt.location?.absoluteString == "https://www.notion.so/page-1")
        let requests = await transport.requests
        #expect(requests.map(\.httpMethod) == ["POST", "PATCH", "PATCH"])
        #expect(requests.map { $0.url?.path } == ["/v1/pages", "/v1/blocks/page-1/children", "/v1/blocks/page-1/children"])
        let resumed = NetworkTestRig.object(requests[2])
        #expect((resumed["children"] as? [Any])?.count == 51)
        #expect(await engine.pending().isEmpty)
    }

    @Test("a transcript that changed since the failed send starts a new page")
    func notionFingerprintMismatch() async throws {
        let transport = StubTransport(fallback: NetworkTestRig.json(["id": "page-2"]))
        let (destination, _) = notion(environment: NetworkTestRig.environment(transport: transport))
        let payload = NetworkTestRig.manySegmentsPayload(paragraphs: 150)

        _ = try await destination.deliver(payload, resume: "page-1|100|deadbeef|")

        let requests = await transport.requests
        #expect(requests.first?.httpMethod == "POST")
        #expect(requests.first?.url?.path == "/v1/pages")
    }

    private func partialToken(
        _ destination: NotionDestination, payload: DeliveryPayload
    ) async throws -> String {
        do {
            _ = try await destination.deliver(payload)
        } catch let error as DeliveryError {
            if case .partialDelivery(_, _, _, _, let resume) = error { return resume }
        }
        throw DeliveryError.pageNotReturned("no partial delivery happened")
    }

    @Test("a resume aimed at a trashed page starts a new one in the same attempt", arguments: [
        (404, ""), (400, "Can't edit block that is archived. You must unarchive the block before editing."),
    ])
    func resumeOntoTrashedPage(status: Int, message: String) async throws {
        let transport = StubTransport(script: [
            .success(NetworkTestRig.json(["id": "page-1"])),
            .success(HTTPResult(status: 500)),
            .success(NetworkTestRig.json(["message": message], status: status)),
            .success(NetworkTestRig.json(["id": "page-2", "url": "https://www.notion.so/page-2"])),
        ])
        let (destination, _) = notion(environment: NetworkTestRig.environment(transport: transport))
        let payload = NetworkTestRig.manySegmentsPayload(paragraphs: 150)
        let token = try await partialToken(destination, payload: payload)

        let receipt = try await destination.deliver(payload, resume: token)

        let requests = await transport.requests
        #expect(requests.map(\.httpMethod) == ["POST", "PATCH", "PATCH", "POST", "PATCH"])
        #expect(requests.map { $0.url?.path } == [
            "/v1/pages", "/v1/blocks/page-1/children", "/v1/blocks/page-1/children",
            "/v1/pages", "/v1/blocks/page-2/children",
        ])
        #expect(receipt.location?.absoluteString == "https://www.notion.so/page-2")
    }

    @Test("when the new page fails too, the failure follows the permanence table")
    func resumeOntoTrashedPageThenRefused() async throws {
        let transport = StubTransport(script: [
            .success(NetworkTestRig.json(["id": "page-1"])),
            .success(HTTPResult(status: 500)),
            .success(HTTPResult(status: 404)),
            .success(HTTPResult(status: 404)),
        ])
        let (destination, _) = notion(environment: NetworkTestRig.environment(transport: transport))
        let payload = NetworkTestRig.manySegmentsPayload(paragraphs: 150)
        let token = try await partialToken(destination, payload: payload)

        do {
            _ = try await destination.deliver(payload, resume: token)
            Issue.record("expected a failure")
        } catch let error as DeliveryError {
            #expect(error == .httpStatus("Notes", 404, ""))
            #expect(error.isPermanent)
        }
        #expect(await transport.requests.count == 4, "one new page was tried, once")
    }

    @Test("other refusals of a resumed append are not read as a trashed page")
    func resumeOtherFailureStaysPartial() async throws {
        let transport = StubTransport(script: [
            .success(NetworkTestRig.json(["id": "page-1"])),
            .success(HTTPResult(status: 500)),
            .success(NetworkTestRig.json(["message": "Body failed validation"], status: 400)),
        ])
        let (destination, _) = notion(environment: NetworkTestRig.environment(transport: transport))
        let payload = NetworkTestRig.manySegmentsPayload(paragraphs: 150)
        let token = try await partialToken(destination, payload: payload)

        do {
            _ = try await destination.deliver(payload, resume: token)
            Issue.record("expected a failure")
        } catch let error as DeliveryError {
            guard case .partialDelivery = error else {
                Issue.record("wrong error \(error)")
                return
            }
        }
        #expect(await transport.requests.count == 3)
    }

    @Test("moving the destination to another parent page starts a new page")
    func resumeFingerprintCoversParent() async throws {
        let transport = StubTransport(script: [
            .success(NetworkTestRig.json(["id": "page-1"])),
            .success(HTTPResult(status: 500)),
        ], fallback: NetworkTestRig.json(["id": "page-2"]))
        let (destination, _) = notion(environment: NetworkTestRig.environment(transport: transport))
        let payload = NetworkTestRig.manySegmentsPayload(paragraphs: 150)
        let token = try await partialToken(destination, payload: payload)
        var moved = destination
        moved.parentPageID = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"

        _ = try await moved.deliver(payload, resume: token)

        let all = await transport.requests
        let third = try #require(all.dropFirst(2).first)
        #expect(third.httpMethod == "POST")
        #expect(NetworkTestRig.object(third)["parent"] as? [String: String] == ["page_id": "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"])
    }

    @Test("an answer with no page in it stops the delivery instead of risking a second page")
    func pageNotReturned() async throws {
        let transport = StubTransport(script: [.success(NetworkTestRig.json(["object": "page"]))])
        let (destination, _) = notion(environment: NetworkTestRig.environment(transport: transport))

        await #expect(throws: DeliveryError.pageNotReturned("Notes")) {
            try await destination.deliver(NetworkTestRig.manySegmentsPayload(paragraphs: 3))
        }
    }

    @Test("a redirect the policy refused is reported as a moved address and not retried", .logFacade)
    func refusedRedirect() async throws {
        let transport = StubTransport(script: [.success(HTTPResult(status: 307, headers: ["location": "https://elsewhere.example/hook"]))])
        let destination = AnyDestination.webhook(webhook(environment: NetworkTestRig.environment(transport: transport)))
        let directory = tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let engine = engine(for: destination, directory: directory)

        let outcome = await engine.send(entryID: "entry-1", to: destination.id)

        #expect(outcome == .skipped(reason: .rejected("Zap", .redirected("Zap", status: 307))))
        #expect(DeliverySkipReason.rejected("Zap", .redirected("Zap", status: 307)).message
            == "Zap has moved to another address (HTTP 307). Update its address in Send To settings.")
        #expect(await engine.pending().isEmpty)
    }

    @Test("a failure that is not a partial one keeps the page the queue already holds", .logFacade)
    func laterFailureKeepsResume() async throws {
        let variant = PayloadVariant()
        let transport = StubTransport(script: [
            .success(NetworkTestRig.json(["id": "page-1"])),
            .success(HTTPResult(status: 500)),
            .success(HTTPResult(status: 500)),
        ])
        let (destination, _) = notion(environment: NetworkTestRig.environment(transport: transport))
        let stored = AnyDestination.notion(destination)
        let directory = tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let engine = DeliveryEngine(
            destinations: { [stored] },
            payload: { id in
                var payload = NetworkTestRig.manySegmentsPayload(paragraphs: await variant.paragraphs)
                payload.entryID = id
                return payload
            },
            store: DeliveryQueueStore(directory: directory),
            clock: TestClock()
        )

        _ = await engine.send(entryID: "entry-1", to: stored.id)
        let pending = await engine.pending()
        let held = try #require(pending.first?.resume)
        await variant.set(120)
        _ = await engine.send(entryID: "entry-1", to: stored.id)

        #expect(await engine.pending().first?.resume == held, "the second attempt failed creating a page, so the first page is still the one to finish")
    }

    @Test("a send cancelled partway keeps its progress for the retry", .logFacade)
    func notionCancelledPartway() async throws {
        let gated = GatedTransport()
        let directory = tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (destination, _) = notion(environment: DeliveryEnvironment(secrets: InMemorySecretStore(), transport: { _ in gated }))
        let payload = NetworkTestRig.manySegmentsPayload(paragraphs: 150)

        let task = Task { try await destination.deliver(payload) }
        #expect(await pollUntil { await gated.arrivals == 1 })
        await gated.release(.success(NetworkTestRig.json(["id": "page-1"])))
        #expect(await pollUntil { await gated.arrivals == 2 })
        task.cancel()
        await gated.release(.failure(URLError(.cancelled)))

        do {
            _ = try await task.value
            Issue.record("expected a failure")
        } catch let error as DeliveryError {
            guard case .partialDelivery(_, let sent, _, let underlying, let resume) = error else {
                Issue.record("wrong error \(error)")
                return
            }
            #expect(sent == 100)
            #expect(underlying == .networkFailed("api.notion.com", .cancelled))
            #expect(resume.hasPrefix("page-1|100|"))
        }
    }

    @Test("cancelling an entry while a slow send is in flight does not queue it again", .logFacade)
    func cancelDuringSend() async throws {
        let gated = GatedTransport()
        let slow = AnyDestination.webhook(WebhookDestination(
            name: "Zap", urlText: "https://hooks.example.com/catch/1",
            environment: DeliveryEnvironment(secrets: InMemorySecretStore(), transport: { _ in gated })
        ))
        let directory = tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let engine = engine(for: slow, directory: directory)

        let sending = Task { await engine.send(entryID: "entry-1", to: slow.id) }
        #expect(await pollUntil { await gated.arrivals == 1 })
        await engine.cancel(entryID: "entry-1")
        await gated.release(.success(HTTPResult(status: 500)))
        let outcome = await sending.value

        guard case .skipped = outcome else {
            Issue.record("expected skipped, got \(outcome)")
            return
        }
        #expect(await engine.pending().isEmpty)
        #expect(await engine.recentLog().last?.event == .dropped)
    }

    @Test("a slow network destination does not hold up the others in an automatic send", .logFacade)
    func autoSendRunsTogether() async throws {
        let gated = GatedTransport()
        let slow = AnyDestination.webhook(WebhookDestination(
            name: "Slow hook", autoSend: true, urlText: "https://hooks.example.com/catch/1",
            environment: DeliveryEnvironment(secrets: InMemorySecretStore(), transport: { _ in gated })
        ))
        let recorder = MockDeliveryRecorder()
        let fast = MockDestination(name: "Fast vault", autoSend: true, recorder: recorder)
        let directory = tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let engine = DeliveryEngine(
            destinations: { [slow, .mock(fast)] },
            payload: { id in
                var payload = ObsidianNoteRendererTests.payload()
                payload.entryID = id
                return payload
            },
            store: DeliveryQueueStore(directory: directory),
            clock: TestClock()
        )
        let progress = ProgressLog()

        let all = Task { await engine.sendAutomatically(entryID: "entry-1") { await progress.add($0) } }
        #expect(await pollUntil { await progress.names == ["Fast vault"] })
        #expect(await gated.arrivals == 1, "the slow hook is still waiting")
        await gated.release(.success(HTTPResult(status: 200)))
        let attempts = await all.value

        #expect(attempts.map(\.destinationName) == ["Slow hook", "Fast vault"], "the result keeps the list order")
        #expect(attempts.allSatisfy { $0.outcome.isDelivered })
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
