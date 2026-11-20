import AppKit
import Foundation
import Observation
import SwiftUI
import XippiSession
import XippiStore

/// The user's preferences, kept in `UserDefaults` under `eu.xippi.*`. One instance per
/// process, injected through the environment.
@MainActor @Observable final class AppSettings {
    enum Appearance: String, CaseIterable, Identifiable {
        case system, light, dark
        var id: String { rawValue }
        var colorScheme: ColorScheme? {
            switch self {
            case .system: nil
            case .light: .light
            case .dark: .dark
            }
        }
    }

    /// Defaults and limits, shared with the views.
    enum Limits {
        static let defaultDownloadSize: Int64 = 10 * 1024 * 1024
        static let minimumTextSize = 14.0
        static let maximumTextSize = 32.0
        static let defaultAutoAwayMinutes = 5
    }

    private enum Key {
        static let fileDownloadSizeLimit = "eu.xippi.fileDownloadSizeLimit"
        static let linkPreviews = "eu.xippi.linkPreviews"
        static let typingNotifications = "eu.xippi.typingNotifications"
        static let readMarkersInRooms = "eu.xippi.readMarkersInRooms"
        static let notificationsFromUnknownSenders = "eu.xippi.notificationsFromUnknownSenders"
        static let notificationMessageText = "eu.xippi.notificationMessageText"
        static let notifyLevelDefault = "eu.xippi.notifyLevelDefault"
        static let keywords = "eu.xippi.keywords"
        static let showMenuBarItem = "eu.xippi.showMenuBarItem"
        static let usePublicSTUN = "eu.xippi.usePublicSTUN"
        static let showAdvancedFeatures = "eu.xippi.showAdvancedFeatures"
        static let autoAwayAfterMinutes = "eu.xippi.autoAwayAfterMinutes"
        static let appearance = "eu.xippi.appearance"
        static let messageTextSize = "eu.xippi.messageTextSize"
        static let sendOnReturn = "eu.xippi.sendOnReturn"
    }

    @ObservationIgnored private let defaults: UserDefaults

    /// Largest file fetched without asking, in bytes. 0 asks for every file.
    var fileDownloadSizeLimit: Int64 {
        didSet { defaults.set(fileDownloadSizeLimit, forKey: Key.fileDownloadSizeLimit) }
    }
    /// Link previews, for known senders only.
    var linkPreviews: Bool {
        didSet { defaults.set(linkPreviews, forKey: Key.linkPreviews) }
    }
    /// Chat states (XEP-0085): tells a chat when the user types.
    var typingNotifications: Bool {
        didSet { defaults.set(typingNotifications, forKey: Key.typingNotifications) }
    }
    /// XEP-0333 displayed markers in rooms that show real JIDs: everyone there sees what the
    /// user has read. Off by default.
    var readMarkersInRooms: Bool {
        didSet { defaults.set(readMarkersInRooms, forKey: Key.readMarkersInRooms) }
    }
    var notificationsFromUnknownSenders: Bool {
        didSet {
            defaults.set(
                notificationsFromUnknownSenders, forKey: Key.notificationsFromUnknownSenders)
        }
    }
    /// What notifications show of a message's text (R58); the system's "Show previews" can
    /// only narrow it.
    var notificationMessageText: NotificationPolicy.MessageText {
        didSet {
            defaults.set(notificationMessageText.rawValue, forKey: Key.notificationMessageText)
        }
    }
    /// For group chats created or joined from now on; each keeps its own afterwards. Direct
    /// chats always notify for every message.
    var notifyLevelDefault: NotifyLevel {
        didSet { defaults.set(notifyLevelDefault.rawValue, forKey: Key.notifyLevelDefault) }
    }
    var keywords: [String] {
        didSet { defaults.set(keywords, forKey: Key.keywords) }
    }
    var showMenuBarItem: Bool {
        didSet { defaults.set(showMenuBarItem, forKey: Key.showMenuBarItem) }
    }
    var usePublicSTUN: Bool {
        didSet { defaults.set(usePublicSTUN, forKey: Key.usePublicSTUN) }
    }
    var showAdvancedFeatures: Bool {
        didSet { defaults.set(showAdvancedFeatures, forKey: Key.showAdvancedFeatures) }
    }
    /// Minutes of inactivity before status goes to away. 0 is off.
    var autoAwayAfterMinutes: Int {
        didSet { defaults.set(autoAwayAfterMinutes, forKey: Key.autoAwayAfterMinutes) }
    }
    var appearance: Appearance {
        didSet { defaults.set(appearance.rawValue, forKey: Key.appearance) }
    }
    /// Message text size in points; nil follows the system's text size.
    var messageTextSize: Double? {
        didSet {
            if let size = messageTextSize {
                guard size.isFinite else {
                    messageTextSize = oldValue
                    return
                }
                let clamped = Self.clampTextSize(size)
                if clamped != size {
                    messageTextSize = clamped
                    return
                }
                defaults.set(size, forKey: Key.messageTextSize)
            } else {
                defaults.removeObject(forKey: Key.messageTextSize)
            }
        }
    }
    var sendOnReturn: Bool {
        didSet { defaults.set(sendOnReturn, forKey: Key.sendOnReturn) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        func bool(_ key: String, _ fallback: Bool) -> Bool {
            defaults.object(forKey: key) as? Bool ?? fallback
        }
        let storedLimit = (defaults.object(forKey: Key.fileDownloadSizeLimit) as? NSNumber)?
            .int64Value
        fileDownloadSizeLimit = storedLimit.map { max($0, 0) } ?? Limits.defaultDownloadSize
        linkPreviews = bool(Key.linkPreviews, true)
        typingNotifications = bool(Key.typingNotifications, true)
        readMarkersInRooms = bool(Key.readMarkersInRooms, false)
        notificationsFromUnknownSenders = bool(Key.notificationsFromUnknownSenders, false)
        notificationMessageText =
            defaults.string(forKey: Key.notificationMessageText)
            .flatMap(NotificationPolicy.MessageText.init(rawValue:)) ?? .default
        notifyLevelDefault =
            defaults.string(forKey: Key.notifyLevelDefault).flatMap(NotifyLevel.init(rawValue:))
            ?? .mentions
        keywords = Self.normalized(defaults.stringArray(forKey: Key.keywords) ?? [])
        showMenuBarItem = bool(Key.showMenuBarItem, false)
        usePublicSTUN = bool(Key.usePublicSTUN, false)
        showAdvancedFeatures = bool(Key.showAdvancedFeatures, false)
        autoAwayAfterMinutes = max(
            defaults.object(forKey: Key.autoAwayAfterMinutes) as? Int
                ?? Limits.defaultAutoAwayMinutes, 0)
        appearance =
            defaults.string(forKey: Key.appearance).flatMap(Appearance.init(rawValue:)) ?? .system
        messageTextSize = (defaults.object(forKey: Key.messageTextSize) as? Double)
            .flatMap { $0.isFinite ? Self.clampTextSize($0) : nil }
        sendOnReturn = bool(Key.sendOnReturn, true)
    }

    static func clampTextSize(_ size: Double) -> Double {
        min(max(size, Limits.minimumTextSize), Limits.maximumTextSize)
    }

    /// Keywords trimmed, without blanks and without repeats (ignoring case).
    static func normalized(_ keywords: [String]) -> [String] {
        var seen = Set<String>()
        return keywords.compactMap { raw in
            let word = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !word.isEmpty, seen.insert(word.lowercased()).inserted else { return nil }
            return word
        }
    }

    /// Adds a keyword typed by the person; false if it is blank or already there.
    @discardableResult
    func addKeyword(_ raw: String) -> Bool {
        let updated = Self.normalized(keywords + [raw])
        guard updated.count > keywords.count else { return false }
        keywords = updated
        return true
    }

    func removeKeywords(at offsets: IndexSet) {
        keywords.remove(atOffsets: offsets)
    }
}
