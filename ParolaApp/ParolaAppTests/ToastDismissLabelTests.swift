import AppKit
import SwiftUI
import Testing
@testable import Parola
import ParolaCore
import ParolaTestSupport

@MainActor
@Suite("Toast close buttons", .serialized)
struct ToastDismissLabelTests {
    private func dismissLabel(of view: some View, model: AppModel) -> String? {
        let hosted = HostedWindow(view.environment(model), width: 700, height: 120)
        defer { hosted.close() }
        return HostedAccessibility.elements(in: hosted.host)
            .first { $0.identifier?.hasSuffix(".Button.Dismiss") == true }?.label
    }

    @Test("every toast's ✕ is called Dismiss")
    func everyCloseButtonIsNamed() {
        let model = AppModel(bootstrap: AppBootstrap(
            mode: .test, library: makeTempLibraryURL("toast-dismiss"), defaultsOverride: temporaryDefaults(),
            sideEffects: [], filePicker: TestFilePicker(), clock: ContinuousClock()
        ))
        let export = ExportNotice(message: "Export failed: disk full", failures: [], folder: nil, tone: .failure)
        let arrival = ArrivalNotice(failed: URL(fileURLWithPath: "/tmp/watched/interview.m4a"), reason: "The file is damaged.")
        let delivery = DeliveryNotice(entryID: "E", destinationID: UUID(), destinationName: "Vault", state: .failed("Gone."))

        #expect(dismissLabel(of: ExportNoticeStrip(notice: export), model: model) == "Dismiss")
        #expect(dismissLabel(of: ArrivalToast(notice: arrival), model: model) == "Dismiss")
        #expect(dismissLabel(of: DeliveryToast(notice: delivery), model: model) == "Dismiss")
        #expect(dismissLabel(of: TakeSavedToast(notice: TakeSavedNotice(entryID: "E", category: .meeting)), model: model) == "Dismiss")
    }
}
