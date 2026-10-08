import Foundation
import Testing
import UserNotifications
@testable import Parola
import ParolaCore
import ParolaTestSupport

/// Stands in for the notification center: it records what Parola posts and withdraws, and answers the permission question as the test says.
@MainActor
private final class FakeNotificationCenter: MeetingNotificationCenter {
    var status: UNAuthorizationStatus
    var grants: Bool
    var statusReads = 0
    var asks = 0
    var registered: [UNNotificationCategory] = []
    var posted: [UNNotificationRequest] = []
    var withdrawn: [String] = []
    private var heldAnswer: CheckedContinuation<Void, Never>?
    var holdsAnswer = false

    init(status: UNAuthorizationStatus = .authorized, grants: Bool = true) {
        self.status = status
        self.grants = grants
    }

    func register(_ category: UNNotificationCategory, delegate: any UNUserNotificationCenterDelegate) {
        registered.append(category)
    }

    func authorizationStatus() async -> UNAuthorizationStatus {
        statusReads += 1
        return status
    }

    func requestAuthorization() async -> Bool {
        asks += 1
        if holdsAnswer { await withCheckedContinuation { heldAnswer = $0 } }
        if grants { status = .authorized }
        return grants
    }

    func answer() {
        heldAnswer?.resume()
        heldAnswer = nil
    }

    func post(_ request: UNNotificationRequest) {
        posted.append(request)
    }

    func withdraw(_ identifier: String) {
        withdrawn.append(identifier)
    }
}

@MainActor
private final class Flag {
    var value: Bool
    init(_ value: Bool) { self.value = value }
}

@MainActor
@Suite("Meeting notification")
struct MeetingNotifierTests {
    enum Exit: String, CaseIterable, CustomTestStringConvertible {
        case appQuits, takeStarts, recordInWindow, notNowInWindow, detectionOff
        var testDescription: String { rawValue }
    }

    private struct Rig {
        let model: AppModel
        let center: FakeNotificationCenter
        let notifier: MeetingNotifier
        let inView: Flag
        let broughtForward: Calls
    }

    private func rig(_ label: String, center: FakeNotificationCenter = FakeNotificationCenter(), inView: Bool = false) -> Rig {
        let model = makeRecordingModel("meeting-notifier-\(label)")
        model.useStreaming = false
        model.meetingRecordsMicrophone = false
        model.takeCaptureOverride = { _ in StubSource(url: URL(fileURLWithPath: "/dev/null")) }
        model.meetingDetector.isEnabled = true
        let flag = Flag(inView)
        let calls = Calls()
        let notifier = MeetingNotifier(
            center: center,
            promptInView: { flag.value },
            bringForward: { _ in calls.count += 1 }
        )
        notifier.bind(model)
        center.withdrawn.removeAll()
        return Rig(model: model, center: center, notifier: notifier, inView: flag, broughtForward: calls)
    }

    private func italianBundle() throws -> Bundle {
        let path = try #require(Bundle.main.path(forResource: "it", ofType: "lproj"))
        return try #require(Bundle(path: path))
    }

    @Test("binding registers Record Meeting and Not Now, and clears a notification an earlier launch left")
    func bindRegistersTheCategory() {
        let center = FakeNotificationCenter()
        let model = makeRecordingModel("meeting-notifier-bind")
        let notifier = MeetingNotifier(center: center, promptInView: { false })

        notifier.bind(model)

        #expect(model.meetingNotifier === notifier)
        #expect(center.registered.map(\.identifier) == [MeetingNotifier.categoryID])
        #expect(center.registered.first?.actions.map(\.title) == ["Record Meeting", "Not Now"])
        #expect(center.registered.first?.actions.first?.options.contains(.foreground) == false)
        #expect(center.registered.first?.actions.last?.options.contains(.foreground) == false)
        #expect(center.withdrawn == [MeetingNotifier.requestID])
    }

    @Test("a prompt raised while the main window is key posts nothing and asks nothing")
    func keyWindowPostsNothing() async {
        let rig = rig("key", inView: true)

        rig.model.meetingDetector.fire(appName: "Acme Conference")
        await settle()

        #expect(rig.model.meetingDetectedApp == "Acme Conference")
        #expect(rig.center.posted.isEmpty)
        #expect(rig.center.statusReads == 0)
        #expect(rig.center.asks == 0)
    }

    @Test("a prompt the launch scan raised before this notifier existed posts once bind catches up")
    func launchScanPostsAtBind() async {
        let center = FakeNotificationCenter()
        let model = makeRecordingModel("meeting-notifier-launch-scan")
        model.meetingDetectedApp = "Acme Conference"
        let notifier = MeetingNotifier(center: center, promptInView: { false })

        notifier.bind(model)
        let posted = await waitUntil { center.posted.count == 1 }

        #expect(posted)
        #expect(notifier.postedApp == "Acme Conference")
    }

    @Test("bind checks nothing when the window can already show the waiting prompt")
    func bindPostsNothingWithTheWindowKey() async {
        let center = FakeNotificationCenter()
        let model = makeRecordingModel("meeting-notifier-launch-scan-key")
        model.meetingDetectedApp = "Acme Conference"
        let notifier = MeetingNotifier(center: center, promptInView: { true })

        notifier.bind(model)
        await settle()

        #expect(center.posted.isEmpty)
        #expect(notifier.postedApp == nil)
    }

    @Test("a prompt raised while the window was key posts once the window stops showing it")
    func windowLostSightPostsALatePrompt() async {
        let rig = rig("lost-sight", inView: true)
        rig.model.meetingDetector.fire(appName: "Acme Conference")
        await settle()
        #expect(rig.center.posted.isEmpty, "the window could show it, so nothing posted yet")

        rig.inView.value = false
        rig.notifier.windowLostSight()
        let posted = await waitUntil { rig.center.posted.count == 1 }

        #expect(posted)
        #expect(rig.notifier.postedApp == "Acme Conference")
    }

    @Test("leaving the front twice posts only once for the same detection")
    func windowLostSightPostsOnlyOnce() async {
        let rig = rig("lost-sight-twice", inView: true)
        rig.model.meetingDetector.fire(appName: "Acme Conference")
        await settle()

        rig.inView.value = false
        rig.notifier.windowLostSight()
        let posted = await waitUntil { rig.center.posted.count == 1 }
        rig.notifier.windowLostSight()
        await settle()

        #expect(posted)
        #expect(rig.center.posted.count == 1)
    }

    @Test("a prompt raised behind Parola's back posts one notification for it, and a second detection posts no other")
    func backgroundedPostsOnce() async {
        let rig = rig("backgrounded")

        rig.model.meetingDetector.fire(appName: "Acme Conference")
        let posted = await waitUntil { rig.center.posted.count == 1 }
        rig.model.meetingDetector.fire(appName: "Other Conference")
        await settle()

        #expect(posted)
        #expect(rig.center.posted.count == 1)
        let request = rig.center.posted.first
        #expect(request?.identifier == MeetingNotifier.requestID)
        #expect(request?.content.title == "Acme Conference is running")
        #expect(request?.content.body == "Record this meeting with Parola?")
        #expect(request?.content.categoryIdentifier == MeetingNotifier.categoryID)
        #expect(request?.content.userInfo[MeetingNotifier.appKey] as? String == "Acme Conference")
        #expect(rig.notifier.postedApp == "Acme Conference")
    }

    @Test("the notification goes when the prompt does", arguments: Exit.allCases)
    func withdrawnOnEachExit(_ exit: Exit) async {
        let rig = rig("exit-\(exit.rawValue)")
        rig.model.meetingDetector.fire(appName: "Acme Conference")
        let posted = await waitUntil { rig.center.posted.count == 1 }
        #expect(posted)

        switch exit {
        case .appQuits: rig.model.meetingDetector.quit(appName: "Acme Conference")
        case .takeStarts: rig.model.startRecording(source: .microphone)
        case .recordInWindow: rig.model.startMeetingRecording()
        case .notNowInWindow: rig.model.dismissMeetingPrompt()
        case .detectionOff: rig.model.meetingDetector.isEnabled = false
        }

        #expect(rig.model.meetingDetectedApp == nil)
        #expect(rig.center.withdrawn == [MeetingNotifier.requestID])
        #expect(rig.notifier.postedApp == nil)
        if rig.model.recordingActive {
            await rig.model.discardTake()
            await waitUntil { !rig.model.recordingActive }
        }
        rig.model.meetingDetector.isEnabled = true
    }

    @Test("Record Meeting on the notification starts one meeting take, and pressing it again starts no other")
    func recordFromTheNotificationStartsOneTake() async {
        let rig = rig("record")
        rig.model.meetingDetector.fire(appName: "Acme Conference")
        let posted = await waitUntil { rig.center.posted.count == 1 }
        #expect(posted)

        rig.notifier.respond(to: MeetingNotifier.recordActionID, app: "Acme Conference")
        let take = rig.model.recording?.takeID
        rig.notifier.respond(to: MeetingNotifier.recordActionID, app: "Acme Conference")

        #expect(take != nil)
        #expect(rig.model.recording?.takeID == take)
        #expect(rig.model.activeTake?.category == .meeting)
        #expect(rig.model.recording?.source == .systemAudio)
        #expect(rig.model.meetingDetectedApp == nil)
        #expect(rig.center.withdrawn == [MeetingNotifier.requestID])
        #expect(rig.broughtForward.count == 0, "Record starts the take in place, as the menu bar's Record does")
        await rig.model.discardTake()
        await waitUntil { !rig.model.recordingActive }
    }

    @Test("Not Now on the notification answers the prompt as its own Not Now does, and starts nothing")
    func notNowFromTheNotification() async {
        let rig = rig("not-now")
        rig.model.meetingDetector.fire(appName: "Acme Conference")
        let posted = await waitUntil { rig.center.posted.count == 1 }
        #expect(posted)

        rig.notifier.respond(to: MeetingNotifier.notNowActionID, app: "Acme Conference")

        #expect(rig.model.meetingDetectedApp == nil)
        #expect(rig.model.recording == nil)
        #expect(rig.center.withdrawn == [MeetingNotifier.requestID])
        #expect(rig.broughtForward.count == 0)
    }

    @Test("a notification answered after its prompt went starts no take")
    func staleAnswerDoesNothing() async {
        let rig = rig("stale")
        rig.model.meetingDetector.fire(appName: "Acme Conference")
        let posted = await waitUntil { rig.center.posted.count == 1 }
        #expect(posted)
        rig.model.dismissMeetingPrompt()

        rig.notifier.respond(to: MeetingNotifier.recordActionID, app: "Acme Conference")
        rig.notifier.respond(to: MeetingNotifier.notNowActionID, app: "Acme Conference")

        #expect(rig.model.recording == nil)
    }

    @Test("clicking the notification brings Parola forward with the prompt still up")
    func clickBringsParolaForward() async {
        let rig = rig("click")
        rig.model.meetingDetector.fire(appName: "Acme Conference")
        let posted = await waitUntil { rig.center.posted.count == 1 }
        #expect(posted)

        rig.notifier.respond(to: UNNotificationDefaultActionIdentifier, app: "Acme Conference")

        #expect(rig.broughtForward.count == 1)
        #expect(rig.model.meetingDetectedApp == "Acme Conference")
        #expect(rig.model.recording == nil)
        #expect(rig.center.withdrawn.isEmpty)
    }

    @Test("permission is asked once, the first time there is something to post")
    func asksOnceThenPosts() async {
        let rig = rig("ask-once", center: FakeNotificationCenter(status: .notDetermined, grants: true))
        #expect(rig.center.asks == 0, "binding asks nothing")

        rig.model.meetingDetector.fire(appName: "Acme Conference")
        let first = await waitUntil { rig.center.posted.count == 1 }
        rig.model.dismissMeetingPrompt()
        rig.model.meetingDetector.fire(appName: "Other Conference")
        let second = await waitUntil { rig.center.posted.count == 2 }

        #expect(first)
        #expect(second)
        #expect(rig.center.asks == 1)
    }

    @Test("a refused or unanswered permission posts nothing, and Parola doesn't ask again", arguments: [
        UNAuthorizationStatus.denied, .notDetermined,
    ])
    func refusedPermissionPostsNothing(_ status: UNAuthorizationStatus) async {
        let rig = rig("refused-\(status.rawValue)", center: FakeNotificationCenter(status: status, grants: false))

        rig.model.meetingDetector.fire(appName: "Acme Conference")
        let read = await waitUntil { rig.center.statusReads == 1 }
        await settle()
        rig.model.dismissMeetingPrompt()
        rig.model.meetingDetector.fire(appName: "Other Conference")
        let readAgain = await waitUntil { rig.center.statusReads == 2 }
        await settle()

        #expect(read)
        #expect(readAgain)
        #expect(rig.center.posted.isEmpty)
        #expect(rig.center.asks == (status == .notDetermined ? 1 : 0))
    }

    @Test("a permission granted after the prompt was answered posts nothing")
    func lateGrantPostsNothing() async {
        let center = FakeNotificationCenter(status: .notDetermined, grants: true)
        center.holdsAnswer = true
        let rig = rig("late-grant", center: center)
        rig.model.meetingDetector.fire(appName: "Acme Conference")
        let asked = await waitUntil { center.asks == 1 }
        #expect(asked)

        rig.model.dismissMeetingPrompt()
        center.answer()
        await settle()

        #expect(center.posted.isEmpty)
        #expect(rig.notifier.postedApp == nil)
    }

    @Test("with meeting detection off, a meeting app posts nothing")
    func detectionOffPostsNothing() async {
        let rig = rig("detection-off")
        rig.model.meetingDetector.isEnabled = false

        rig.model.meetingDetector.fire(appName: "Acme Conference")
        await settle()

        #expect(rig.model.meetingDetectedApp == nil)
        #expect(rig.center.posted.isEmpty)
        #expect(rig.center.statusReads == 0)
        rig.model.meetingDetector.isEnabled = true
    }

    @Test("only a launch that watches for meetings for real reaches the notification center; no test host or sandbox does")
    func onlyARealLaunchNotifies() throws {
        let host = try #require(AppBootstrap.testHost(environment: ["XCTestConfigurationFilePath": ""]))
        let sandbox = try #require(AppBootstrap.test(from: ["Parola", "--test-mode"], environment: [:]))
        #expect(AppDelegate.postsMeetingNotifications(BootstrapSideEffect.all))
        #expect(!AppDelegate.postsMeetingNotifications(host.sideEffects))
        #expect(!AppDelegate.postsMeetingNotifications(sandbox.sideEffects))
        #expect(!AppDelegate.postsMeetingNotifications(BootstrapSideEffect.all.subtracting(
            FeatureSet(enabled: [.micRecording]).excludedSideEffects(mode: .normal)
        )), "a build without meetings has nothing to notify about")
        #expect(makeRecordingModel("meeting-notifier-none").meetingNotifier == nil)
    }

    @Test("the notification and its buttons read in Italian")
    func italianCopy() throws {
        let bundle = try italianBundle()
        let request = MeetingNotifier.request(for: "Zoom", bundle: bundle)
        let category = MeetingNotifier.category(bundle: bundle)

        #expect(request.content.title == "Zoom è in esecuzione")
        #expect(request.content.body == "Registrare questa riunione con Parola?")
        #expect(category.actions.map(\.title) == ["Registra riunione", "Non ora"])
    }
}
