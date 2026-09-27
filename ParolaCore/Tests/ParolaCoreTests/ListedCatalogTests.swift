import Foundation
import Testing
@testable import ParolaCore

@Suite("Listed model catalog")
struct ListedCatalogTests {
    private static let v2 = "nvidia_parakeet-tdt-0.6b-v2"
    private static let v3 = "nvidia_parakeet-tdt-0.6b-v3"

    private func scan(installed: Set<String> = []) -> ModelScan {
        let catalog = ModelCatalog.all.map { variant in
            ModelInfo(
                name: variant.id,
                label: variant.displayName,
                approximateSizeBytes: Int(variant.sizeBytes),
                isMultilingual: !(variant.languageScope?.isEnglishOnly ?? false),
                isInstalled: installed.contains(variant.id)
            )
        }
        return ModelScan(catalog: catalog, installed: catalog.filter(\.isInstalled))
    }

    @Test("the earlier Parakeet is listed only once it is installed")
    func earlierParakeetIsHiddenUntilInstalled() {
        let without = scan().listedCatalog.map(\.name)
        #expect(!without.contains(Self.v2))
        #expect(without.contains(Self.v3))
        #expect(without.count == ModelCatalog.all.count - 1)

        #expect(scan(installed: [Self.v2]).listedCatalog.map(\.name).contains(Self.v2))
    }

    @Test("the listed catalog holds the variants the pickers group")
    func listedCatalogMatchesThePickers() {
        let listed = scan().listedCatalog.map(\.name).sorted()
        let grouped = ModelCatalog.groupedForPicker(configuration: ManagedConfiguration(plistOverride: [:]), isInstalled: { _ in false })
            .flatMap(\.1)
            .map(\.id)
            .sorted()
        #expect(listed == grouped)
    }

    @Test("a store with nothing installed does not list the earlier Parakeet")
    func storeListsWithoutTheEarlierParakeet() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("parola-listed-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ModelStore(modelsDirectory: dir, managedConfiguration: ManagedConfiguration(plistOverride: [:]))

        let listed = store.listedCatalog().map(\.name)

        #expect(!listed.contains(Self.v2))
        #expect(listed.contains(Self.v3))
    }
}
