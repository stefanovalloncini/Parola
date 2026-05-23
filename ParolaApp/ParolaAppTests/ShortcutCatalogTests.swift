import Foundation
import Testing
@testable import Parola

@Suite("Shortcut catalog")
struct ShortcutCatalogTests {
    @Test("catalog has at least four sections")
    func sectionCount() {
        #expect(ShortcutCatalog.sections.count >= 4)
    }

    @Test("every section has at least one entry")
    func sectionsNonEmpty() {
        for section in ShortcutCatalog.sections {
            #expect(section.entries.isEmpty == false)
        }
    }

    @Test("section titles are unique")
    func uniqueSections() {
        let titles = ShortcutCatalog.sections.map(\.title)
        #expect(Set(titles).count == titles.count)
    }

    @Test("entry labels and keys are non-empty")
    func entriesValid() {
        for section in ShortcutCatalog.sections {
            for entry in section.entries {
                #expect(entry.label.isEmpty == false)
                #expect(entry.keys.isEmpty == false)
            }
        }
    }
}
