import Foundation
import SwiftUI

@MainActor
final class UserSettings: ObservableObject {
    @AppStorage("selectedModel") var modelName: String = "openai_whisper-tiny"
    @AppStorage("selectedLanguageRaw") private var languageRaw: String = ""
    @AppStorage("translate") var translate: Bool = false
    @AppStorage("wordTimestamps") var wordTimestamps: Bool = true
    @AppStorage("initialPrompt") var initialPrompt: String = ""

    var language: String? {
        get { languageRaw.isEmpty ? nil : languageRaw }
        set { languageRaw = newValue ?? "" }
    }
}
