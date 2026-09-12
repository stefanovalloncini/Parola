import SwiftUI
import ParolaCore

struct ChatMessageList: View {
    let history: [ChatMessage]
    let searchQuery: String
    let senderFilter: ChatSenderFilter
    let isSending: Bool

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    let visible = filteredHistory
                    let trimmedQuery = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
                    if history.isEmpty {
                        ChatHint()
                            .padding(.top, DS.Spacing.xlarge)
                    } else if visible.isEmpty && !trimmedQuery.isEmpty {
                        ContentUnavailableView.search(text: trimmedQuery)
                            .padding(.top, DS.Spacing.xlarge)
                    } else if visible.isEmpty && hasActiveFilter {
                        ContentUnavailableView("No Messages", systemImage: "line.3.horizontal.decrease.circle")
                            .padding(.top, DS.Spacing.xlarge)
                    }
                    ForEach(visible) { msg in
                        ChatBubble(message: msg).id(msg.id)
                    }
                    if isSending {
                        ChatThinkingIndicator(isActive: isSending)
                            .id("thinking")
                    }
                }
                .padding(.horizontal, DS.Spacing.medium)
                .padding(.vertical, DS.Spacing.regular)
            }
            .onChange(of: history.count) { _, _ in
                scrollToEnd(proxy: proxy)
            }
            .onChange(of: isSending) { _, sending in
                if sending { scrollToEnd(proxy: proxy) }
            }
        }
    }

    private var filteredHistory: [ChatMessage] {
        let trimmed = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        return history.filter { msg in
            guard senderFilter.matches(msg.role) else { return false }
            if trimmed.isEmpty { return true }
            return msg.text.range(of: trimmed, options: .caseInsensitive) != nil
        }
    }

    private var hasActiveFilter: Bool {
        !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || senderFilter != .all
    }

    private func scrollToEnd(proxy: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.2)) {
            if isSending {
                proxy.scrollTo("thinking", anchor: .bottom)
            } else if let last = history.last {
                proxy.scrollTo(last.id, anchor: .bottom)
            }
        }
    }
}
