import Foundation
import Testing
@testable import Parola
import ParolaCore

@Suite("Shortcut catalog")
struct ShortcutCatalogTests {
    @Test("catalog has at least four sections")
    func sectionCount() {
        #expect(ShortcutCatalog.sections(features: .all).count >= 4)
    }

    @Test("every section has at least one entry")
    func sectionsNonEmpty() {
        for section in ShortcutCatalog.sections(features: .all) {
            #expect(section.entries.isEmpty == false)
        }
    }

    @Test("section titles are unique")
    func uniqueSections() {
        let titles = ShortcutCatalog.sections(features: .all).map(\.title)
        #expect(Set(titles).count == titles.count)
    }

    @Test("entry labels and keys are non-empty")
    func entriesValid() {
        for section in ShortcutCatalog.sections(features: .all) {
            for entry in section.entries {
                #expect(entry.label.isEmpty == false)
                #expect(entry.keys.isEmpty == false)
            }
        }
    }
}
