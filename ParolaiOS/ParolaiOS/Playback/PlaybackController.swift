import Foundation
import SwiftUI
import ParolaCore

@MainActor
final class PlaybackController: ObservableObject {
    @Published private(set) var currentTime: TimeInterval = 0
    @Published private(set) var isPlaying = false
    @Published private(set) var duration: TimeInterval = 0

    func load(audioURL: URL, transcript: Transcript) {}
    func play() {}
    func pause() {}
    func toggle() {}
    func seek(to time: TimeInterval) {}
}
