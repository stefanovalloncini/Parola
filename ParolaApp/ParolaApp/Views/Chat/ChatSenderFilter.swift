import ParolaCore

enum ChatSenderFilter: CaseIterable, Hashable {
    case all, user, assistant

    var label: String {
        switch self {
        case .all: return "All"
        case .user: return "User"
        case .assistant: return "Assistant"
        }
    }

    func matches(_ role: ChatMessage.Role) -> Bool {
        switch self {
        case .all: return true
        case .user: return role == .user
        case .assistant: return role == .assistant
        }
    }
}
