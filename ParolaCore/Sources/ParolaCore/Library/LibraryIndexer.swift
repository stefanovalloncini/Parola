import Foundation

public protocol LibraryIndexer: Sendable {
    func index(id: String, title: String, text: String, createdAt: Date) async
    func deindex(id: String) async
}
