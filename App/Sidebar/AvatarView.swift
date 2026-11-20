import SwiftUI

/// The contact's or room's avatar, clipped to the chat's shape (a circle for a person, a
/// rounded square for a group); initials on the chat's XEP-0392 colour while there is none.
struct AvatarView: View {
    let name: String
    let identifier: String
    var isGroup = false
    var size: CGFloat = ControlHeight.Sidebar.avatar
    /// The stored avatar's hash (`ChatRecord.avatarHash`, `RosterItemRecord.avatarHash`).
    var hash: String?

    @Environment(\.avatarImages) private var avatars

    var body: some View {
        let shape = isGroup ? AnyShape(.rect(cornerRadius: size * 0.28)) : AnyShape(.circle)
        Group {
            if let hash, let avatars {
                AvatarImageView(entry: avatars.entry(for: hash), initials: initials)
            } else {
                initials
            }
        }
        .frame(width: size, height: size)
        .background(IdentityColor.avatar(for: identifier))
        .clipShape(shape)
        .accessibilityHidden(true)
    }

    private var initials: some View {
        Text(ChatDisplay.initials(of: name))
            .font(.system(size: max(size * 0.4, 14), weight: .semibold, design: .rounded))
            .foregroundStyle(.white)
    }
}

/// The image once read, the initials until then: only this view follows the image.
private struct AvatarImageView<Initials: View>: View {
    let entry: AvatarImages.Entry
    let initials: Initials

    var body: some View {
        if let image = entry.image {
            Image(nsImage: image)
                .resizable()
                .scaledToFill()
        } else {
            initials
        }
    }
}

extension EnvironmentValues {
    /// The main window's avatar cache; nil outside it, where initials show.
    @Entry var avatarImages: AvatarImages?
}

/// Short dates for lists, in the viewer's time zone: a time today, "Yesterday", a weekday within
/// a week, otherwise a date.
enum RelativeDay {
    static func short(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) {
            return date.formatted(date: .omitted, time: .shortened)
        }
        if isYesterday(date, now: now, calendar: calendar) { return Copy.yesterday }
        let startOfToday = calendar.startOfDay(for: now)
        if let weekAgo = calendar.date(byAdding: .day, value: -6, to: startOfToday), date >= weekAgo
        {
            return date.formatted(.dateTime.weekday(.abbreviated))
        }
        return date.formatted(date: .numeric, time: .omitted)
    }

    /// Day separators in the transcript.
    static func long(_ day: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        if calendar.isDate(day, inSameDayAs: now) { return Copy.today }
        if isYesterday(day, now: now, calendar: calendar) { return Copy.yesterday }
        if calendar.isDate(day, equalTo: now, toGranularity: .year) {
            return day.formatted(.dateTime.weekday(.wide).day().month(.wide))
        }
        return day.formatted(.dateTime.weekday(.wide).day().month(.wide).year())
    }

    /// Measured from `now`, not from the clock, so a caller's `now` is honoured.
    private static func isYesterday(_ date: Date, now: Date, calendar: Calendar) -> Bool {
        guard let yesterday = calendar.date(byAdding: .day, value: -1, to: now) else {
            return false
        }
        return calendar.isDate(date, inSameDayAs: yesterday)
    }
}
