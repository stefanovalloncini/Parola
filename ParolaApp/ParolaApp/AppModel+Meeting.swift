import Foundation
import SwiftUI
import ParolaCore

extension AppModel {

    func startMeetingRecording() {
        meetingDetectedApp = nil
        pendingRecordingCategory = .meeting
        startRecording(source: .systemAudio)
    }

    func dismissMeetingPrompt() {
        meetingDetectedApp = nil
    }
}
