import SwiftUI

extension DS.Color {
    /// The words a live take has not settled yet: #6E6E73 is 5.07:1 on white, #98989D 5.46:1 on the dark window.
    static let liveTailTheme = ThemeColor.dynamic(
        light: RGBA(0.431, 0.431, 0.451),
        dark: RGBA(0.596, 0.596, 0.616)
    )
    static let liveTail = liveTailTheme.color
}

extension DS.Font {
    static let takeTimerCompact = SwiftUI.Font.system(size: 13, weight: .medium, design: .rounded).monospacedDigit()
    static let takeTimerStage = SwiftUI.Font.system(size: 56, weight: .light, design: .rounded).monospacedDigit()
    /// A line of words in the clock's slot, while the take has no time to show yet.
    static let takePreparingStage = SwiftUI.Font.system(size: 28, weight: .light, design: .rounded).monospacedDigit()
    static let liveTranscriptStage = SwiftUI.Font.system(size: 24, design: .serif)
    static let footnoteDigits = SwiftUI.Font.system(size: 11).monospacedDigit()
}

extension DS.Motion {
    static let takeEntry = SwiftUI.Animation.spring(duration: 0.35, bounce: 0.12)
    static let sidebarCollapse = SwiftUI.Animation.spring(duration: 0.35, bounce: 0)
    static let transcriptFollow = SwiftUI.Animation.easeOut(duration: 0.3)
    static let controlsMorph = SwiftUI.Animation.spring(duration: 0.45, bounce: 0.15)
}
