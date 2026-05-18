import Foundation

struct RecentFilesList: Equatable {
    private(set) var urls: [URL] = []
    let capacity: Int

    init(capacity: Int = 10) {
        self.capacity = max(1, capacity)
    }

    mutating func note(_ url: URL) {
        urls.removeAll { $0 == url }
        urls.insert(url, at: 0)
        if urls.count > capacity {
            urls.removeLast(urls.count - capacity)
        }
    }

    mutating func forget(_ url: URL) {
        urls.removeAll { $0 == url }
    }

    mutating func clear() {
        urls.removeAll()
    }

    var encoded: String {
        let paths = urls.map(\.absoluteString)
        let data = (try? JSONEncoder().encode(paths)) ?? Data()
        return String(data: data, encoding: .utf8) ?? "[]"
    }

    mutating func decode(_ raw: String) {
        guard let data = raw.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([String].self, from: data) else {
            return
        }
        urls = decoded.compactMap { URL(string: $0) }.prefix(capacity).map { $0 }
    }
}
