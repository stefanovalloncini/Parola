import SwiftUI
import ParolaCore

struct ChatMessageList: View {
    let history: [ChatMessage]
    let live: LiveReply
    let searchQuery: String
    let senderFilter: ChatSenderFilter
    let isSending: Bool
    var failure: String?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    let visible = filteredHistory
                    let trimmedQuery = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
                    let liveShows = live.replyID != nil && senderFilter.matches(.assistant)
                    if history.isEmpty && !liveShows {
                        ChatHint()
                            .padding(.top, DS.Spacing.xlarge)
                    } else if visible.isEmpty && !liveShows && !trimmedQuery.isEmpty {
                        ContentUnavailableView.search(text: trimmedQuery)
                            .padding(.top, DS.Spacing.xlarge)
                    } else if visible.isEmpty && !liveShows && hasActiveFilter {
                        ContentUnavailableView("No Messages", systemImage: "line.3.horizontal.decrease.circle")
                            .padding(.top, DS.Spacing.xlarge)
                    }
                    ForEach(visible) { msg in
                        ChatBubble(message: msg).id(msg.id)
                    }
                    if let replyID = live.replyID {
                        LiveReplyBubble(live: live, replyID: replyID, searchQuery: searchQuery, senderFilter: senderFilter)
                            .id(replyID)
                    }
                    if isSending {
                        ChatThinkingIndicator(isActive: isSending)
                            .id("thinking")
                    } else if let failure {
                        ChatTurnFailure(message: failure)
                            .id("failure")
                    }
                }
                .padding(.horizontal, DS.Spacing.medium)
                .padding(.vertical, DS.Spacing.regular)
            }
            .onChange(of: history.count) { _, _ in
                scrollToEnd(proxy: proxy)
            }
            .onChange(of: live.replyID) { _, replyID in
                if replyID != nil { scrollToEnd(proxy: proxy) }
            }
            .onChange(of: isSending) { _, sending in
                if sending { scrollToEnd(proxy: proxy) }
            }
            .onChange(of: failure) { _, failure in
                guard failure != nil else { return }
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("failure", anchor: .bottom) }
            }
        }
    }

    private var filteredHistory: [ChatMessage] {
        history.filter { Self.matches($0, searchQuery: searchQuery, senderFilter: senderFilter) }
    }

    static func matches(_ message: ChatMessage, searchQuery: String, senderFilter: ChatSenderFilter) -> Bool {
        guard senderFilter.matches(message.role) else { return false }
        let trimmed = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return true }
        return message.text.range(of: trimmed, options: .caseInsensitive) != nil
    }

    private var hasActiveFilter: Bool {
        !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || senderFilter != .all
    }

    private func scrollToEnd(proxy: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.2)) {
            if isSending {
                proxy.scrollTo("thinking", anchor: .bottom)
            } else if let replyID = live.replyID {
                proxy.scrollTo(replyID, anchor: .bottom)
            } else if let last = history.last {
                proxy.scrollTo(last.id, anchor: .bottom)
            }
        }
    }
}
