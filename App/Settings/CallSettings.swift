import SwiftUI

struct CallSettings: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section {
                Toggle(Copy.publicSTUN, isOn: $settings.usePublicSTUN)
                    .pointerStyle(.link)
            }
        }
        .formStyle(.grouped)
        .font(.appBody)
        .accessibilityIdentifier("settings-calls")
    }
}
