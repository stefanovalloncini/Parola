import Foundation

enum FavoriteRemap {
    static func afterSplit(_ favorites: Set<Int>, of id: Int, into firstID: Int) -> Set<Int> {
        guard favorites.contains(id) else { return favorites }
        var out = favorites
        out.remove(id)
        out.insert(firstID)
        return out
    }

    static func afterMerge(_ favorites: Set<Int>, of id: Int, with nextID: Int) -> Set<Int> {
        var out = favorites
        let keep = out.contains(id) || out.contains(nextID)
        out.remove(nextID)
        if keep { out.insert(id) } else { out.remove(id) }
        return out
    }

    static func afterDelete(_ favorites: Set<Int>, of id: Int) -> Set<Int> {
        var out = favorites
        out.remove(id)
        return out
    }
}
