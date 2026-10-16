import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import ParolaCore
import ParolaDictation
import ScreenCaptureKit
import Vision

struct MacContextSource: DictationContextSource {
    // DispatchQueue, not Task.detached: detached jobs around XPC-bridging calls (AX here)
    // have crashed twice with SIGBUS EXC_ARM_DA_ALIGN in runJobInEstablishedExecutorContext.
    func currentSelection() async -> String? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: readSelectionViaAccessibility())
            }
        }
    }

    func clipboardContents() async -> String? {
        await MainActor.run {
            PendingPasteRestores.userText()
        }
    }

    func windowOCR() async -> String? {
        do {
            let cgImage = try await captureFrontmostWindow()
            return try await recognizeText(in: cgImage)
        } catch {
            return nil
        }
    }

    private func readSelectionViaAccessibility() -> String? {
        let systemWide = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        let focusedResult = AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &focused
        )
        guard focusedResult == .success, let element = focused else { return nil }
        let axElement = element as! AXUIElement
        var selectedText: CFTypeRef?
        let textResult = AXUIElementCopyAttributeValue(
            axElement,
            kAXSelectedTextAttribute as CFString,
            &selectedText
        )
        guard textResult == .success, let value = selectedText as? String else { return nil }
        return value.isEmpty ? nil : value
    }

    private func captureFrontmostWindow() async throws -> CGImage {
        let content = try await SCShareableContent.current
        guard let frontmostApp = await MainActor.run(body: { NSWorkspace.shared.frontmostApplication }) else {
            throw ContextError.noFrontmostApp
        }
        let pid = frontmostApp.processIdentifier
        let candidate = content.windows.first { window in
            window.owningApplication?.processID == pid
                && window.isOnScreen
                && window.frame.width > 100
                && window.frame.height > 100
        }
        guard let window = candidate else { throw ContextError.noWindow }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = SCStreamConfiguration()
        config.width = Int(window.frame.width)
        config.height = Int(window.frame.height)
        config.showsCursor = false
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }

    private func recognizeText(in image: CGImage) async throws -> String? {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                // Vision can report a failure through the completion AND throw from
                // perform; the box keeps the continuation to a single resume.
                let resumed = ResumeBox()
                let request = VNRecognizeTextRequest { request, error in
                    guard resumed.claim() else { return }
                    if let error {
                        continuation.resume(throwing: error)
                        return
                    }
                    guard let results = request.results as? [VNRecognizedTextObservation] else {
                        continuation.resume(returning: nil)
                        return
                    }
                    let lines = results.compactMap { $0.topCandidates(1).first?.string }
                    let joined = lines.joined(separator: "\n")
                    continuation.resume(returning: joined.isEmpty ? nil : joined)
                }
                request.recognitionLevel = .fast
                request.usesLanguageCorrection = false
                let handler = VNImageRequestHandler(cgImage: image, options: [:])
                do {
                    try handler.perform([request])
                } catch {
                    guard resumed.claim() else { return }
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    // @unchecked is safe: the only state is `taken`, guarded by the lock.
    private final class ResumeBox: @unchecked Sendable {
        private let lock = NSLock()
        private var taken = false

        func claim() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if taken { return false }
            taken = true
            return true
        }
    }

    private enum ContextError: Error {
        case noFrontmostApp
        case noWindow
    }
}
