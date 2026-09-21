import Testing
@testable import Parola
import ParolaCore
import ParolaTestSupport

@MainActor
@Suite("Model listing hides retired variants")
struct ModelListingTests {
    @Test("v2 is listed only when the model store reports it installed")
    func hiddenUnlessInstalled() {
        let none = ModelCatalog.listedVariants(isInstalled: { _ in false }).map(\.id)
        #expect(!none.contains("nvidia_parakeet-tdt-0.6b-v2"))
        let grouped = ModelCatalog.groupedForPicker(isInstalled: { _ in false })
        let fastest = grouped.first { $0.0 == .fastest }?.1.map(\.id) ?? []
        #expect(fastest == ["nvidia_parakeet-tdt-0.6b-v3"])
        let withV2 = ModelCatalog.groupedForPicker(isInstalled: { $0 == "nvidia_parakeet-tdt-0.6b-v2" })
        let fastestWithV2 = withV2.first { $0.0 == .fastest }?.1.map(\.id) ?? []
        #expect(fastestWithV2.contains("nvidia_parakeet-tdt-0.6b-v2"))
    }
}
