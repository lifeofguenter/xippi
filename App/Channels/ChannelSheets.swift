import Observation
import SwiftUI

/// Which channel sheet the main window shows.
enum ChannelSheet: String, Identifiable {
    case join, create
    var id: String { rawValue }
}

/// The main window's channel sheet, handed to the menu commands while that window is in front.
@MainActor @Observable final class ChannelSheetState {
    var sheet: ChannelSheet?
}

/// The join and create channel sheets over the main window. A channel joined opens.
struct ChannelSheets: ViewModifier {
    let model: AppModel
    @State private var state = ChannelSheetState()

    func body(content: Content) -> some View {
        content
            .focusedSceneValue(state)
            .sheet(item: $state.sheet) { sheet in
                switch sheet {
                case .join:
                    JoinChannelSheet(model: model, accountID: nil, channel: nil, onDone: done)
                case .create:
                    CreateChannelSheet(model: model, onDone: done)
                }
            }
    }

    private func done(_ chatID: Int64?) {
        state.sheet = nil
        if let chatID { model.open(chatID: chatID) }
    }
}

/// File > Join channel and Create channel, for the main window in front.
struct ChannelCommands: Commands {
    @FocusedValue(ChannelSheetState.self) private var sheets

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button(Copy.joinChannelMenu) { sheets?.sheet = .join }
                .disabled(sheets == nil)
            Button(Copy.createChannelMenu) { sheets?.sheet = .create }
                .disabled(sheets == nil)
        }
    }
}
