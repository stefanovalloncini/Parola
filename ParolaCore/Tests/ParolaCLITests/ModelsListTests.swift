import Foundation
import Testing
import ParolaCore
@testable import parola

@Suite("parola models list")
struct ModelsListTests {
    private static let v2 = "nvidia_parakeet-tdt-0.6b-v2"
    private static let v3 = "nvidia_parakeet-tdt-0.6b-v3"

    private func catalog(installed: Set<String> = []) -> [ModelInfo] {
        ModelCatalog.all.map { variant in
            ModelInfo(
                name: variant.id,
                label: variant.displayName,
                approximateSizeBytes: Int(variant.sizeBytes),
                isMultilingual: !(variant.languageScope?.isEnglishOnly ?? false),
                isInstalled: installed.contains(variant.id)
            )
        }
    }

    @Test("the earlier Parakeet is listed only once it is installed")
    func earlierParakeetIsHiddenUntilInstalled() {
        let withoutIt = Models.List.listedRows(catalog()).map(\.name)
        #expect(!withoutIt.contains(Self.v2))
        #expect(withoutIt.contains(Self.v3))

        let withIt = Models.List.listedRows(catalog(installed: [Self.v2])).map(\.name)
        #expect(withIt.contains(Self.v2))
    }

    @Test("--json and --flat list the same rows as the grouped listing")
    func everyListingShowsTheSameRows() throws {
        let rows = Models.List.listedRows(catalog())

        let decoded = try JSONDecoder().decode(
            [ModelInfo].self, from: Data(try Models.List.jsonText(rows).utf8)
        )
        #expect(decoded.map(\.name) == rows.map(\.name))
        #expect(!decoded.contains { $0.name == Self.v2 })

        let flat = Models.List.flatLines(rows)
        #expect(flat.count == rows.count)
        #expect(!flat.contains { $0.contains(Self.v2) })
        #expect(flat.contains { $0.contains(Self.v3) })

        let grouped = ModelCatalog.groupedForPicker(isInstalled: { _ in false })
            .flatMap(\.1)
            .map(\.id)
        #expect(grouped.sorted() == rows.map(\.name).sorted())
    }
}
