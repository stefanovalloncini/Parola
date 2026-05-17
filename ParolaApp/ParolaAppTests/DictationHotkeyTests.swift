import Carbon.HIToolbox
import Foundation
import Testing
@testable import Parola

@Suite("DictationHotkey")
struct DictationHotkeyTests {
    @Test("f5 matches kVK_F5")
    func f5MatchesCarbonCode() {
        #expect(DictationHotkey.f5.rawValue == Int(kVK_F5))
    }

    @Test("every case has a unique key code")
    func uniqueKeyCodes() {
        let codes = DictationHotkey.allCases.map(\.rawValue)
        #expect(Set(codes).count == codes.count)
    }

    @Test("displayName matches the rawValue position")
    func displayNamesAreLabelled() {
        for hotkey in DictationHotkey.allCases {
            #expect(hotkey.displayName.hasPrefix("F"))
        }
    }

    @Test("displayNames are unique")
    func displayNamesUnique() {
        let names = DictationHotkey.allCases.map(\.displayName)
        #expect(Set(names).count == names.count)
    }
}
