import Testing
@testable import Parola

@Suite("Favorite remap rules")
struct FavoriteRemapTests {
    @Test("split keeps the favorite on the first half")
    func split() {
        #expect(FavoriteRemap.afterSplit([4, 9], of: 4, into: 20) == [9, 20])
        #expect(FavoriteRemap.afterSplit([9], of: 4, into: 20) == [9])
    }

    @Test("merge keeps the favorite if either segment had it")
    func merge() {
        #expect(FavoriteRemap.afterMerge([5], of: 4, with: 5) == [4])
        #expect(FavoriteRemap.afterMerge([4], of: 4, with: 5) == [4])
        #expect(FavoriteRemap.afterMerge([8], of: 4, with: 5) == [8])
    }

    @Test("delete drops it")
    func delete() {
        #expect(FavoriteRemap.afterDelete([4, 8], of: 4) == [8])
    }
}
