public enum StoreError: Error, Equatable, Sendable {
    case migrationFailed(name: String)
    /// A message or read marker names a chat that does not exist.
    case chatNotFound(id: Int64)
    /// A message names a chat of another account.
    case chatAccountMismatch(chatID: Int64)
}
