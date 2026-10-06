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

    @Test("the bridge reports the same buttons the toast draws")
    func bridgeButtons() {
        #expect(ParolaAutomationServer.arrivalButtons(failed()) == [.retry, .reveal, .dismiss])
    }
}
