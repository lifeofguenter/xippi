import SwiftUI

struct GeneralSettings: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section {
                Toggle(Copy.showMenuBarItem, isOn: $settings.showMenuBarItem)
                    .pointerStyle(.link)
                Toggle(isOn: $settings.sendOnReturn) {
                    Text(Copy.sendOnReturn)
                    if !settings.sendOnReturn {
                        Text(Copy.sendOnReturnHelp)
                    }
                }
                .pointerStyle(.link)
            }
            Section {
                Picker(Copy.autoAway, selection: $settings.autoAwayAfterMinutes) {
                    Text(Copy.autoAwayOff).tag(0)
                    ForEach(Self.awayChoices, id: \.self) { minutes in
                        Text(Copy.minutes(minutes)).tag(minutes)
                    }
                    if settings.autoAwayAfterMinutes != 0,
                        !Self.awayChoices.contains(settings.autoAwayAfterMinutes)
                    {
                        Text(Copy.minutes(settings.autoAwayAfterMinutes))
                            .tag(settings.autoAwayAfterMinutes)
                    }
                }
                .pointerStyle(.link)
            }
        }
        .formStyle(.grouped)
        .font(.appBody)
        .accessibilityIdentifier("settings-general")
    }

    private static let awayChoices = [1, 2, 5, 10, 15, 30, 60]
}
