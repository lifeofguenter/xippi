import SwiftUI

struct AdvancedSettings: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section {
                Toggle(isOn: $settings.showAdvancedFeatures) {
                    Text(Copy.advancedFeatures)
                    Text(Copy.advancedFeaturesHelp)
                }
                .pointerStyle(.link)
                .accessibilityIdentifier("show-advanced-features")
            }
        }
        .formStyle(.grouped)
        .font(.appBody)
        .accessibilityIdentifier("settings-advanced")
    }
}
