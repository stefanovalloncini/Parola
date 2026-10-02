import SwiftUI

/// The take's light where a colour alone would carry its state: a pause sign while it pauses, else the recording dot.
struct TakeLight: View {
    let take: RecordingSession
    var pulsesFrom: Date?

    nonisolated static let pauseSymbol = "pause.fill"

    /// The sign drawn in the dot's place; nil while the dot shows.
    nonisolated static func symbol(for take: RecordingSession) -> String? {
        take.isPaused ? pauseSymbol : nil
    }

    var body: some View {
        if let symbol = Self.symbol(for: take) {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(TakeRemote.Lamp.paused.tint.color)
                .accessibilityHidden(true)
        } else {
            RecDot(color: TakeRemote.lamp(for: take).tint.color, pulsesFrom: pulsesFrom)
        }
    }
}
