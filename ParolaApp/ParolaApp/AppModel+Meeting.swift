import Foundation
import SwiftUI
import ParolaCore

extension AppModel {

    func startMeetingRecording() {
        if meetingCaptureAppOnly, let app = meetingDetectedApp {
            pendingCaptureBundleIDs = MeetingDetector.bundleIDs(forAppName: app)
        }
        meetingDetectedApp = nil
        pendingRecordingCategory = .meeting
        startRecording(source: .systemAudio)
    }

    func dismissMeetingPrompt() {
        if let app = meetingDetectedApp {
            meetingDetector.snooze(appName: app)
        }
        meetingDetectedApp = nil
    }
}
