import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Parola
import ParolaCore
import ParolaTestSupport

@MainActor
@Suite("A watched file that failed", .serialized)
struct FailedArrivalToastTests {
    private let file = URL(fileURLWithPath: "/tmp/parola-watched/interview.m4a")

    private func makeModel() -> AppModel {
        AppModel(skipBootstrap: true, defaults: temporaryDefaults(), libraryURL: makeTempLibraryURL("failed-arrival"))
    }

    private func failed() -> ArrivalNotice {
        ArrivalNotice(failed: file, reason: "The file is damaged.")
    }

    @Test("the failure stays until it is dismissed, like the toast's other failures")
    func failureStays() {
        #expect(failed().dismissesItself == false)
    }

    @Test("the failure offers Retry and Reveal beside its close button")
    func failureHasAWayOut() {
        let model = makeModel()
        let notice = failed()
        model.arrivalNotice = notice
        let hosted = HostedWindow(ArrivalToast(notice: notice).environment(model), width: 700, height: 140)
        defer { hosted.close() }
        let ids = HostedAccessibility.elements(in: hosted.host).compactMap(\.identifier)
        #expect(ids.contains { $0.hasSuffix("Arrival.Button.Retry") })
        #expect(ids.contains { $0.hasSuffix("Arrival.Button.Reveal") })
        #expect(ids.contains { $0.hasSuffix("Arrival.Button.Dismiss") })
    }

    @Test("Retry puts the file back in the watched-folder line and takes the toast down")
    func retryQueuesTheFileAgain() {
        let model = makeModel()
        let folderID = UUID()
        let notice = ArrivalNotice(failed: file, reason: "The file is damaged.", folderID: folderID, folderPath: "/tmp/parola-watched")
        model.arrivalNotice = notice
        let hosted = HostedWindow(ArrivalToast(notice: notice).environment(model), width: 700, height: 140)
        defer { hosted.close() }

        #expect(HostedAccessibility.press(endingWith: "Arrival.Button.Retry", in: hosted.host))

        #expect(model.arrivalNotice == nil)
        let queued = model.watchedArrivals.first { $0.url == file }
        #expect(queued?.folderID == folderID)
        #expect(queued?.folderPath == "/tmp/parola-watched")
    }

    @Test("Reveal points at the file while it is there, then at its folder, then nowhere once the folder is gone too")
    func revealFindsWhatIsLeft() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("failed-arrival-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("interview.m4a")
        try Data([0]).write(to: file)
        #expect(AppModel.arrivalReveal(file: file, folderPath: folder.path) == .file(file))

        try FileManager.default.removeItem(at: file)
        #expect(AppModel.arrivalReveal(file: file, folderPath: folder.path) == .folder(folder))

        let inGoneSubfolder = folder.appendingPathComponent("old/interview.m4a")
        #expect(AppModel.arrivalReveal(file: inGoneSubfolder, folderPath: folder.path) == .folder(folder))

        try FileManager.default.removeItem(at: folder)
        #expect(AppModel.arrivalReveal(file: file, folderPath: folder.path) == .gone)
    }

    @Test("Reveal on a file whose folder went too says the file was moved or deleted, and Retry stays")
    func revealSaysTheFileIsGone() {
        let model = makeModel()
        let missing = URL(fileURLWithPath: "/tmp/parola-gone-\(UUID().uuidString)/interview.m4a")
        let folderID = UUID()
        model.arrivalNotice = ArrivalNotice(
            failed: missing, reason: "The file is damaged.", folderID: folderID, folderPath: missing.deletingLastPathComponent().path
        )

        model.revealFailedArrival()

        #expect(model.arrivalNotice?.reason == String(localized: "The file was moved or deleted."))
        #expect(model.arrivalNotice?.file == missing)
        #expect(model.arrivalNotice?.folderID == folderID)
    }

    @Test("the bridge reports the same buttons the toast draws")
    func bridgeButtons() {
        #expect(ParolaAutomationServer.arrivalButtons(failed()) == [.retry, .reveal, .dismiss])
    }
}
