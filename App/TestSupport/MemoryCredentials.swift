#if DEBUG || UITEST_HOOKS
    import Synchronization
    import XMPPCore
    import XippiSession

    /// Passwords and FAST tokens in memory, for UI test launches: nothing reaches the keychain.
    final class MemoryCredentials: CredentialStore {
        private struct Stored {
            var passwords: [String: String] = [:]
            var tokens: [String: FASTToken] = [:]
        }

        private let stored = Mutex(Stored())

        func password(for jid: JID) async -> String? {
            stored.withLock { $0.passwords[jid.bare.description] }
        }

        func fastToken(for jid: JID) async -> FASTToken? {
            stored.withLock { $0.tokens[jid.bare.description] }
        }

        func store(_ token: FASTToken?, for jid: JID) async {
            stored.withLock { $0.tokens[jid.bare.description] = token }
        }

        func setPassword(_ password: String, for jid: JID) throws {
            stored.withLock { $0.passwords[jid.bare.description] = password }
        }

        func remove(for jid: JID) throws {
            stored.withLock { stored in
                stored.passwords[jid.bare.description] = nil
                stored.tokens[jid.bare.description] = nil
            }
        }
    }
#endif
