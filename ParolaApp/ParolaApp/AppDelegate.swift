import AppKit

/// Hosts the macOS Services provider and wires Finder-originated requests into ``AppModel``.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private weak var model: AppModel?
    private let provider = ServicesProvider()
    private var dictationStatusItem: DictationStatusItem?

    func bind(model: AppModel) {
        self.model = model
        provider.model = model
        if dictationStatusItem == nil {
            dictationStatusItem = DictationStatusItem(model: model)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.servicesProvider = provider
        NSUpdateDynamicServices()
        SparkleUpdater.shared.start()
    }
}

/// `@objc` shim exposed to AppKit's Services machinery.
@MainActor
final class ServicesProvider: NSObject {
    weak var model: AppModel?

    @objc func transcribeFile(_ pasteboard: NSPasteboard, userData: String?, error errorPtr: AutoreleasingUnsafeMutablePointer<NSString>?) {
        handle(pasteboard: pasteboard, translate: false, errorPtr: errorPtr)
    }

    @objc func translateFile(_ pasteboard: NSPasteboard, userData: String?, error errorPtr: AutoreleasingUnsafeMutablePointer<NSString>?) {
        handle(pasteboard: pasteboard, translate: true, errorPtr: errorPtr)
    }

    private func handle(pasteboard: NSPasteboard, translate: Bool, errorPtr: AutoreleasingUnsafeMutablePointer<NSString>?) {
        guard let url = Self.firstFileURL(from: pasteboard) else {
            errorPtr?.pointee = "No audio or video file found on the pasteboard." as NSString
            return
        }
        guard let model else {
            errorPtr?.pointee = "Parola is not ready." as NSString
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        model.transcribe(fileURL: url, translateOverride: translate)
    }

    /// Returns the first file URL on the pasteboard, accepting either modern `URL` items
    /// or legacy `NSFilenamesPboardType` arrays.
    static func firstFileURL(from pasteboard: NSPasteboard) -> URL? {
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           let url = urls.first {
            return url
        }
        if let names = pasteboard.propertyList(forType: NSPasteboard.PasteboardType("NSFilenamesPboardType")) as? [String],
           let path = names.first {
            return URL(fileURLWithPath: path)
        }
        return nil
    }
}
