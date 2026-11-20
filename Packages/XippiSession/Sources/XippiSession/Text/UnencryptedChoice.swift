/// When choosing Off for a chat that waits for its encryption default asks first (M31, M32):
/// whenever messages may be waiting, which go unencrypted then; also when their number
/// cannot be read (fail closed). Only a count of none skips the question.
public enum UnencryptedChoice {
    public static func asks(waiting: Int?) -> Bool {
        guard let waiting else { return true }
        return waiting > 0
    }
}
