import AppKit
import SwiftUI

extension FocusState<Bool>.Binding {
    /// Asked while the window is still moving focus, the ask lands on another field, so it waits a frame and repeats until it holds.
    @MainActor
    func request(caretAtEnd: Bool = false) async {
        for _ in 0..<10 {
            try? await Task.sleep(for: .milliseconds(20))
            if Task.isCancelled { return }
            if wrappedValue {
                if caretAtEnd { (NSApp.keyWindow?.firstResponder as? NSTextView)?.moveToEndOfDocument(nil) }
                return
            }
            wrappedValue = true
        }
    }
}
