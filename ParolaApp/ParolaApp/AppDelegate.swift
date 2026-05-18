import AppKit
import ParolaCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private weak var model: AppModel?
    private let provider = ServicesProvider()
    private var dictationStatusItem: DictationStatusItem?
    private var dictationSubscription: DictationSubscription?
    private let menuBar = MenuBarController()

    func bind(model: AppModel) {
        self.model = model
        provider.model = model
        if dictationStatusItem == nil {
            dictationStatusItem = DictationStatusItem(model: model)
        }
        menuBar.bind(model)
        if dictationSubscription == nil {
            dictationSubscription = DictationSignal.subscribe { [weak self] name in
                Task { @MainActor [weak self] in
                    guard let model = self?.model else { return }
                    switch name {
                    case DictationSignal.startName: model.startDictationFromIntent()
                    case DictationSignal.stopName:  model.stopDictationFromIntent()
                    default: break
                    }
                }
            }
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.servicesProvider = provider
        NSUpdateDynamicServices()
        SparkleUpdater.shared.start()
    }

    func applicationDidResignActive(_ notification: Notification) {
        model?.handleAppResignedActive()
    }

    func updateDockBadge(for phase: AppModel.Phase) {
        let label: String
        switch phase {
        case .idle, .ready, .failed:
            label = ""
        case .downloadingModel(_, let progress):
            label = "\(Int(progress * 100))%"
        case .loadingModel:
            label = "…"
        case .transcribing:
            label = "•"
        case .recording:
            label = "REC"
        }
        NSApp.dockTile.badgeLabel = label.isEmpty ? nil : label
    }
}

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
