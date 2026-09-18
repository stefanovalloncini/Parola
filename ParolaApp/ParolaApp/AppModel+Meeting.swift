import Foundation
import SwiftUI
import ParolaCore

extension AppModel {

    func startMeetingRecording() {
        guard let app = meetingDetectedApp else {
            meetingDetectedApp = nil
            pendingRecordingCategory = .meeting
            startRecording(source: .systemAudio)
            return
        }
        startMeetingRecording(appName: app)
    }

    func startMeetingRecording(appName: String) {
        if meetingCaptureAppOnly {
            pendingCaptureBundleIDs = MeetingDetector.bundleIDs(forAppName: appName)
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
