import SwiftUI
import ParolaCore

struct LiveReplyBubble: View {
    let live: LiveReply
    let replyID: UUID
    let searchQuery: String
    let senderFilter: ChatSenderFilter

    var body: some View {
        let message = ChatMessage(id: replyID, role: .assistant, text: live.shown)
        if ChatMessageList.matches(message, searchQuery: searchQuery, senderFilter: senderFilter) {
            ChatBubble(message: message)
        }
    }
}
