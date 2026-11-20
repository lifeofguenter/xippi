import SwiftUI

/// ⌘F: the open chat's messages matching a query, in a popover from the toolbar.
struct FindInChat: View {
    let model: AppModel
    let chatID: Int64

    @State private var query = ""
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            TextField(Copy.findInChatPrompt, text: $query)
                .font(.appBody)
                .focused($fieldFocused)
                .accessibilityIdentifier("find-in-chat-field")
                .padding(12)
            Divider()
            if query.trimmingCharacters(in: .whitespaces).isEmpty {
                Spacer(minLength: 0)
            } else {
                SearchResultsView(model: model, query: query, chatID: chatID)
            }
        }
        .frame(width: 380, height: 440)
        .onAppear { fieldFocused = true }
    }
}
