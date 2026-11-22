import SwiftUI
import XippiSession
import XippiStore

/// The account's own avatar, as its profile names it, with the account's status on its corner;
/// initials until there is one.
struct OwnAvatar: View {
    let model: AppModel
    let account: AccountRecord
    var size: CGFloat = ControlHeight.Settings.accountAvatar

    @State private var hash: String?

    var body: some View {
        AvatarView(name: account.jid, identifier: account.jid, size: size, hash: hash)
            .overlay(alignment: .bottomTrailing) {
                StatusDot(status: model.status(of: account))
                    .padding(1.5)
                    .background(.background, in: .circle)
            }
            .task(id: account.id) {
                guard let id = account.id else { return }
                for await profile in model.database.ownProfileUpdates(accountID: id) {
                    hash = profile?.avatarHash
                }
            }
            .accessibilityHidden(true)
    }
}
