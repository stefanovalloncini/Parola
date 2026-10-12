import Foundation

#if DEBUG
@MainActor
enum BodyProbe {
    private static var tallies: [ObjectIdentifier: [String: Int]] = [:]

    static func hit(_ name: String, _ model: AppModel) {
        tallies[ObjectIdentifier(model), default: [:]][name, default: 0] += 1
    }

    static func counts(for model: AppModel) -> [String: Int] {
        tallies[ObjectIdentifier(model)] ?? [:]
    }

    static func reset(for model: AppModel) {
        tallies[ObjectIdentifier(model)] = nil
    }
}
#else
enum BodyProbe {
    @inline(__always) static func hit(_ name: String, _ model: AppModel) {}
}
#endif
