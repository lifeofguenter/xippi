import SwiftUI

struct AppearanceSettings: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section {
                Picker(Copy.appearance, selection: $settings.appearance) {
                    Text(Copy.appearanceSystem).tag(AppSettings.Appearance.system)
                    Text(Copy.appearanceLight).tag(AppSettings.Appearance.light)
                    Text(Copy.appearanceDark).tag(AppSettings.Appearance.dark)
                }
                .pickerStyle(.segmented)
                .pointerStyle(.link)
            }
            Section {
                Toggle(
                    Copy.useSystemTextSize,
                    isOn: Binding(
                        get: { settings.messageTextSize == nil },
                        set: {
                            settings.messageTextSize = $0 ? nil : Typography.bodySize
                        })
                )
                .pointerStyle(.link)
                if let size = settings.messageTextSize {
                    Stepper(
                        value: Binding(
                            get: { size }, set: { settings.messageTextSize = $0 }),
                        in: AppSettings.Limits.minimumTextSize...AppSettings.Limits.maximumTextSize,
                        step: 1
                    ) {
                        LabeledContent(Copy.messageTextSize) {
                            Text(Copy.points(Int(size)))
                                .monospacedDigit()
                        }
                    }
                    .pointerStyle(.link)
                }
            }
        }
        .formStyle(.grouped)
        .font(.appBody)
        .accessibilityIdentifier("settings-appearance")
    }
}
