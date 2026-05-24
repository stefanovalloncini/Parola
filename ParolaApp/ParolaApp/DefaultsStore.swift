import Foundation

enum DefaultsStore {
    nonisolated(unsafe) static var current: UserDefaults = .standard
}
