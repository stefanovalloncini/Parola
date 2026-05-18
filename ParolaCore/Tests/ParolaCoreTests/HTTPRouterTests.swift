import Foundation
import Testing
@testable import ParolaCore

@Suite("HTTP router")
struct HTTPRouterTests {
    @Test("dispatches a GET to a literal path")
    func literalGet() async {
        let router = HTTPRouter()
        await router.route(.GET, "/health") { _ in HTTPResponse(status: 200, body: "ok") }
        let response = await router.dispatch(HTTPRequest(method: .GET, path: "/health"))
        #expect(response.status == 200)
        #expect(response.bodyString == "ok")
    }

    @Test("returns 404 for unknown paths")
    func notFound() async {
        let router = HTTPRouter()
        let response = await router.dispatch(HTTPRequest(method: .GET, path: "/nope"))
        #expect(response.status == 404)
    }

    @Test("405 when path matches but method doesn't")
    func methodNotAllowed() async {
        let router = HTTPRouter()
        await router.route(.GET, "/jobs") { _ in HTTPResponse(status: 200) }
        let response = await router.dispatch(HTTPRequest(method: .POST, path: "/jobs"))
        #expect(response.status == 405)
    }

    @Test("captures :param segments and exposes them on the request")
    func paramSegments() async {
        let router = HTTPRouter()
        await router.route(.GET, "/jobs/:id") { request in
            HTTPResponse(status: 200, body: request.params["id"] ?? "")
        }
        let response = await router.dispatch(HTTPRequest(method: .GET, path: "/jobs/abc123"))
        #expect(response.bodyString == "abc123")
    }

    @Test("matches the most specific route over a parameter route")
    func literalBeatsParam() async {
        let router = HTTPRouter()
        await router.route(.GET, "/jobs/:id") { _ in HTTPResponse(status: 200, body: "param") }
        await router.route(.GET, "/jobs/active") { _ in HTTPResponse(status: 200, body: "literal") }
        let response = await router.dispatch(HTTPRequest(method: .GET, path: "/jobs/active"))
        #expect(response.bodyString == "literal")
    }

    @Test("trailing slashes are ignored")
    func tolerantSlashes() async {
        let router = HTTPRouter()
        await router.route(.GET, "/health") { _ in HTTPResponse(status: 200, body: "ok") }
        let response = await router.dispatch(HTTPRequest(method: .GET, path: "/health/"))
        #expect(response.status == 200)
    }

    @Test("handler can return a JSON response")
    func jsonResponse() async {
        let router = HTTPRouter()
        await router.route(.GET, "/info") { _ in
            HTTPResponse.json(status: 200, ["name": "parola"])
        }
        let response = await router.dispatch(HTTPRequest(method: .GET, path: "/info"))
        #expect(response.status == 200)
        #expect(response.headers["Content-Type"] == "application/json")
        #expect(response.bodyString.contains("parola"))
    }
}
