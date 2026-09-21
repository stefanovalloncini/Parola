import Testing
@testable import Parola

@Suite("Introduction permission card")
struct PermissionCardStatusTests {
    @Test("a granted permission says so and drops its button")
    func granted() {
        let status = PermissionCard.Status(granted: true)
        #expect(status.label == "Granted")
        #expect(!status.showsAction)
    }

    @Test("a missing permission keeps its button")
    func notGranted() {
        let status = PermissionCard.Status(granted: false)
        #expect(status.label == "Not granted")
        #expect(status.showsAction)
    }
}
