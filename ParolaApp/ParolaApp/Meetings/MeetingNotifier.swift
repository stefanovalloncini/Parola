import AppKit
import UserNotifications

/// What a meeting's notification needs of the notification center; a test stands in for the system's.
@MainActor
protocol MeetingNotificationCenter: AnyObject {
    func register(_ category: UNNotificationCategory, delegate: any UNUserNotificationCenterDelegate)
    func authorizationStatus() async -> UNAuthorizationStatus
    func requestAuthorization() async -> Bool
    func post(_ request: UNNotificationRequest)
    func withdraw(_ identifier: String)
}

/// The system's notification center, which only a launch that watches for meetings for real reaches.
@MainActor
final class SystemMeetingNotificationCenter: MeetingNotificationCenter {
    func register(_ category: UNNotificationCategory, delegate: any UNUserNotificationCenterDelegate) {
        let center = UNUserNotificationCenter.current()
        center.setNotificationCategories([category])
        center.delegate = delegate
    }

    nonisolated func authorizationStatus() async -> UNAuthorizationStatus {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    nonisolated func requestAuthorization() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
    }

    func post(_ request: UNNotificationRequest) {
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
    }

    func withdraw(_ identifier: String) {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
        center.removeDeliveredNotifications(withIdentifiers: [identifier])
    }
}

/// The meeting prompt as a notification, for when Parola's window can't show it; its buttons answer as the prompt's do.
@MainActor
final class MeetingNotifier: NSObject {
    nonisolated static let categoryID = "app.parola.meeting"
    nonisolated static let requestID = "app.parola.meeting.prompt"
    nonisolated static let recordActionID = "app.parola.meeting.record"
    nonisolated static let notNowActionID = "app.parola.meeting.notNow"
    nonisolated static let appKey = "meetingApp"

    private weak var model: AppModel?
    private let center: any MeetingNotificationCenter
    private let promptInView: @MainActor () -> Bool
    private let bringForward: @MainActor (AppModel) -> Void
    private var askedForPermission = false
    private var posting: Task<Void, Never>?
    /// The app whose notification is out.
    private(set) var postedApp: String?

    init(
        center: any MeetingNotificationCenter,
        promptInView: @escaping @MainActor () -> Bool,
        bringForward: @escaping @MainActor (AppModel) -> Void = { $0.bringMainWindowForward() }
    ) {
        self.center = center
        self.promptInView = promptInView
        self.bringForward = bringForward
    }

    /// Follows the model's prompt from now on; a notification an earlier launch left behind goes.
    func bind(_ model: AppModel) {
        self.model = model
        model.meetingNotifier = self
        center.register(Self.category(), delegate: self)
        withdraw()
        windowLostSight()
    }

    /// Catches a prompt the window never showed: the launch scan ran before this notifier existed, or Zoom opened
    /// while the window was key and `promptRaised` skipped it. Called once at bind, and again whenever the window
    /// stops being able to show the prompt (`NSApplication.didResignActiveNotification`). Posting once sets
    /// `postedApp`, so a later call for the same detection is a no-op.
    func windowLostSight() {
        guard !promptInView(), let app = model?.meetingDetectedApp, postedApp == nil, posting == nil else { return }
        posting = Task { [weak self] in await self?.post(app) }
    }

    /// Takes the notification out of Notification Center, as a quit must: no prompt is left for its buttons to answer.
    func withdraw() {
        posting?.cancel()
        posting = nil
        postedApp = nil
        center.withdraw(Self.requestID)
    }

    func promptRaised(_ app: String) {
        guard !promptInView() else { return }
        posting?.cancel()
        posting = Task { [weak self] in await self?.post(app) }
    }

    func promptLowered() {
        if postedApp != nil {
            withdraw()
        } else {
            posting?.cancel()
            posting = nil
        }
    }

    /// The prompt may have been answered while the permission question was up, so it is read again before posting.
    private func post(_ app: String) async {
        guard await mayPost(), !Task.isCancelled, model?.meetingDetectedApp == app else { return }
        center.post(Self.request(for: app))
        postedApp = app
    }

    /// Asked once, the first time there is something to post; an answer still pending posts nothing.
    private func mayPost() async -> Bool {
        switch await center.authorizationStatus() {
        case .authorized, .provisional:
            return true
        case .notDetermined:
            guard !askedForPermission else { return false }
            askedForPermission = true
            return await center.requestAuthorization()
        default:
            return false
        }
    }

    /// The notification's buttons act only on the prompt they were posted for; its body brings Parola forward with the prompt up.
    func respond(to action: String, app: String) {
        guard let model else { return }
        switch action {
        case Self.recordActionID:
            guard model.meetingDetectedApp == app else { return }
            model.startMeetingRecording()
        case Self.notNowActionID:
            guard model.meetingDetectedApp == app else { return }
            model.dismissMeetingPrompt()
        case UNNotificationDefaultActionIdentifier:
            bringForward(model)
        default:
            break
        }
    }

    nonisolated static func request(for app: String, bundle: Bundle = .main) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = String(localized: "\(app) is running", bundle: bundle)
        content.body = String(localized: "Record this meeting with Parola?", bundle: bundle)
        content.categoryIdentifier = categoryID
        content.userInfo = [appKey: app]
        content.sound = .default
        return UNNotificationRequest(identifier: requestID, content: content, trigger: nil)
    }

    /// No `.foreground`: Record starts the take in place, as the menu bar's Record does — activating Parola would
    /// pull the user out of a full-screen call to a Space with the Stage, with no way back but a swipe.
    nonisolated static func category(bundle: Bundle = .main) -> UNNotificationCategory {
        let record = UNNotificationAction(
            identifier: recordActionID, title: String(localized: "Record Meeting", bundle: bundle), options: []
        )
        let notNow = UNNotificationAction(identifier: notNowActionID, title: String(localized: "Not Now", bundle: bundle), options: [])
        return UNNotificationCategory(identifier: categoryID, actions: [record, notNow], intentIdentifiers: [], options: [])
    }
}

extension MeetingNotifier: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let request = response.notification.request
        guard request.identifier == Self.requestID, let app = request.content.userInfo[Self.appKey] as? String else { return }
        await respond(to: response.actionIdentifier, app: app)
    }

    /// Posted only when the window can't show the prompt, so it shows even while Parola is the app in front.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }
}
