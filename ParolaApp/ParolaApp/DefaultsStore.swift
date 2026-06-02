import Foundation

enum DefaultsStore {
    /// Set once at bootstrap before any reader; UserDefaults is thread-safe on Darwin.
    nonisolated(unsafe) static var current: UserDefaults = .standard
}
