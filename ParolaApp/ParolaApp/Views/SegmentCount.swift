import Foundation

enum SegmentCount {
    static func label(_ count: Int) -> String {
        count == 1 ? "1 segment" : "\(count) segments"
    }
}
