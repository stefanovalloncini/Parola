import Foundation

#if DEBUG
@MainActor
enum BodyProbe {
    static var counts: [String: Int] = [:]
    static func hit(_ name: String) { counts[name, default: 0] += 1 }
}
#else
enum BodyProbe {
    @inline(__always) static func hit(_ name: String) {}
}
#endif
