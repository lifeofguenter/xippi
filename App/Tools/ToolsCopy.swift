import Foundation
import XMPPCore
import XippiSession

/// The power tools' words: the XML console, service discovery and ad-hoc commands.
extension Copy {
    // MARK: Menu and windows

    static let tools = String(localized: "Tools")
    static let xmlConsole = String(localized: "XML console")
    static let serviceDiscovery = String(localized: "Service discovery")
    static let adHocCommands = String(localized: "Ad-hoc commands")

    // MARK: XML console

    static let directionAll = String(localized: "All")
    static let directionIncoming = String(localized: "Incoming")
    static let directionOutgoing = String(localized: "Outgoing")
    static let direction = String(localized: "Direction")
    static let received = String(localized: "Received")
    static let sent = String(localized: "Sent")
    static let pauseConsole = String(localized: "Pause")
    static let resume = String(localized: "Resume")
    static let prettyPrint = String(localized: "Pretty print")
    static let plainXML = String(localized: "As sent")
    static let copyShown = String(localized: "Copy")
    static let clearConsole = String(localized: "Clear")
    static let consoleFilter = String(localized: "Filter")
    static let noStanzas = String(localized: "No stanzas")
    static let noMatches = String(localized: "No matches")
    static let paused = String(localized: "Paused")
    static let rawXML = String(localized: "Raw XML")
    static let sendXML = String(localized: "Send")

    /// What a console row leaves out: characters cut from the row, and bytes the console did
    /// not keep of a very long element.
    static func notShown(characters: Int, bytes: Int) -> String {
        if bytes > 0 {
            let size = Int64(bytes).formatted(.byteCount(style: .file))
            return String(localized: "Shortened, \(size) not kept")
        }
        return String(localized: "\(characters) more characters")
    }

    static func stanzaCount(_ shown: Int, of total: Int) -> String {
        shown == total
            ? String(localized: "\(total) stanzas")
            : String(localized: "\(shown) of \(total) stanzas")
    }

    static func sendRawTitle(_ jid: String) -> String {
        String(localized: "Send raw XML as \(jid)?")
    }

    /// What is wrong with the send box's text.
    static func consoleProblem(_ problem: StreamTapInput.Problem) -> String {
        switch problem {
        case .empty: String(localized: "Nothing to send")
        case .notWellFormed: String(localized: "Not well-formed XML")
        case .restricted: String(localized: "Comments and processing instructions not allowed")
        case .severalElements: String(localized: "One stanza at a time")
        case .notAStanza: String(localized: "Only message, presence and iq")
        case .tooLarge: String(localized: "Larger than 256 KB")
        }
    }

    // MARK: Service discovery

    static let browse = String(localized: "Browse")
    static let identities = String(localized: "Identities")
    static let features = String(localized: "Features")
    static let extensionForms = String(localized: "Forms")
    static let noItems = String(localized: "No items")
    static let loading = String(localized: "Loading")
    static let node = String(localized: "Node")
    static let commands = String(localized: "Commands")
    static let runCommand = String(localized: "Run")

    static func moreNotShown(_ count: Int) -> String {
        String(localized: "\(count) more not shown")
    }

    static func notAvailable(_ reason: String) -> String {
        String(localized: "Not available: \(reason)")
    }

    // MARK: Ad-hoc commands

    static let noCommands = String(localized: "No commands")
    static let previousStep = String(localized: "Back")
    static let nextStep = String(localized: "Next")
    static let finish = String(localized: "Finish")
    static let runAgain = String(localized: "Run again")
    static let commandCompleted = String(localized: "Completed")
    static let commandCanceled = String(localized: "Cancelled")
    static let noteInfo = String(localized: "Note")
    static let noteWarning = String(localized: "Warning")
    static let noteError = String(localized: "Error")

    static func commandFrom(_ jid: String) -> String {
        String(localized: "From \(jid)")
    }

    /// Rows and columns of a result the table does not show.
    static func tableOmitted(rows: Int, columns: Int) -> String {
        switch (rows > 0, columns > 0) {
        case (true, true):
            String(localized: "\(rows) more rows and \(columns) more columns not shown")
        case (true, false): String(localized: "\(rows) more rows not shown")
        default: String(localized: "\(columns) more columns not shown")
        }
    }

    static func commandFailed(_ reason: String) -> String {
        String(localized: "Command failed: \(reason)")
    }

    // MARK: Errors

    /// A request's failure, as the tools say it after "Not available: " and the like.
    static func toolReason(_ error: IQError) -> String {
        switch error {
        case .notConnected, .sessionEnded: notConnectedReason
        case .timeout: timedOutReason
        case .malformedResponse: String(localized: "no valid answer")
        case .error(let stanzaError): stanzaReason(stanzaError)
        }
    }

    static func toolReason(_ error: SessionError) -> String {
        switch error {
        case .notConnected, .stopped, .unavailable: notConnectedReason
        case .timeout: timedOutReason
        case .refused(let stanzaError): stanzaReason(stanzaError)
        case .invalidInput, .invalidJID: String(localized: "invalid input")
        case .notAllowed: notAllowedReason
        default: String(localized: "failed")
        }
    }

    /// The condition in words, with the entity's own text when it gave one.
    static func stanzaReason(_ error: StanzaError) -> String {
        let condition = words(error.condition.rawValue)
        guard let text = error.text?.trimmingCharacters(in: .whitespacesAndNewlines),
            !text.isEmpty
        else { return condition }
        return "\(condition) (\(text))"
    }
}
