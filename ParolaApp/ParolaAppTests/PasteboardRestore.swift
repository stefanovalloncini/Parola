import AppKit
import Foundation

/// Hands the user's clipboard back after a test of a product path that only copies to `NSPasteboard.general`.
func withPasteboardRestored(
    isolation: isolated (any Actor)? = #isolation,
    _ body: () async throws -> Void
) async rethrows {
    let pasteboard = NSPasteboard.general
    let saved = pasteboard.string(forType: .string)
    defer {
        pasteboard.clearContents()
        if let saved { pasteboard.setString(saved, forType: .string) }
    }
    try await body()
}
