import Foundation
import Testing
@testable import Parola
import ParolaCore

/// Title Case per the macOS HIG: every word capitalized except articles, coordinating
/// conjunctions and prepositions of four letters or fewer.
private func isTitleCase(_ string: String) -> Bool {
    let small: Set<String> = [
        "a", "an", "and", "as", "at", "but", "by", "for", "from", "in", "into",
        "nor", "of", "on", "onto", "or", "the", "to", "up", "via", "with"
    ]
    let words = string.split(separator: " ").map(String.init)
    guard let first = words.first else { return false }
    for word in words {
        for segment in word.split(separator: "-") {
            guard let head = segment.first, head.isLetter else { continue }
            if head.isUppercase { continue }
            if word == first { return false }
            if !small.contains(word.lowercased()) { return false }
        }
    }
    return true
}

@Suite("Copy casing")
struct CopyCasingTests {
    @Test("the shortcut cheat sheet names commands in Title Case")
    func shortcutNamesAreTitleCase() {
        for section in ShortcutCatalog.sections(features: .all) {
            #expect(isTitleCase(section.title), "section \(section.title)")
            for entry in section.entries {
                #expect(isTitleCase(entry.label), "shortcut \(entry.label)")
            }
        }
    }

    @Test("library empty states title in Title Case")
    @MainActor
    func libraryEmptyTitlesAreTitleCase() {
        var titles = [NoResultsView.title]
        for category in EntryCategory.allCases {
            titles.append(LibraryListContent.emptyTitle(for: category))
        }
        for title in titles {
            #expect(isTitleCase(title), "empty state \(title)")
        }
    }

    @Test("Recently Deleted controls share one casing")
    func recentlyDeletedFiltersAreTitleCase() {
        for filter in RecentlyDeletedCategoryFilter.allCases {
            #expect(isTitleCase(filter.title), "kind filter \(filter.title)")
        }
        for option in RecentlyDeletedSort.allCases {
            #expect(isTitleCase(option.title), "sort option \(option.title)")
        }
    }

    @Test("every sort and filter menu uses Title Case, in Italian too")
    func sortAndFilterMenusAreTitleCase() throws {
        let path = try #require(Bundle.main.path(forResource: "it", ofType: "lproj"))
        let italian = try #require(Bundle(path: path))
        let labels = LibrarySortOrder.allCases.map(\.label)
            + QueueView.SortOption.allCases.map(\.rawValue)
            + LibraryDateRangeFilter.allCases.map(\.title)
        for label in labels {
            #expect(isTitleCase(label), "menu item \(label)")
            #expect(italian.localizedString(forKey: label, value: "MISSING", table: nil) != "MISSING", "Italian for \(label)")
        }
    }

    @Test("the casing rule itself rejects sentence case")
    func ruleRejectsSentenceCase() {
        #expect(isTitleCase("Nothing Queued"))
        #expect(isTitleCase("Export as TXT"))
        #expect(!isTitleCase("No jobs yet"))
        #expect(!isTitleCase("mic recording hotkey"))
    }

    @Test("both halves of a hyphenated compound need capitalizing")
    func hyphenatedCompoundsNeedBothHalvesCapitalized() {
        #expect(isTitleCase("Auto-Export"))
        #expect(isTitleCase("Auto-Detect Language"))
        #expect(isTitleCase("Re-Extract"))
        #expect(!isTitleCase("Auto-detect Language"))
        #expect(!isTitleCase("Re-extract"))
    }
}
