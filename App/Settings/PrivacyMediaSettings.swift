import SwiftUI

struct PrivacyMediaSettings: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section {
                Picker(Copy.downloadLimit, selection: $settings.fileDownloadSizeLimit) {
                    Text(Copy.alwaysAsk).tag(Int64(0))
                    ForEach(Self.limitChoices, id: \.self) { megabytes in
                        Text(Copy.megabytes(megabytes)).tag(Int64(megabytes) * Self.megabyte)
                    }
                    if !Self.isChoice(settings.fileDownloadSizeLimit) {
                        Text(Copy.megabytes(Int(settings.fileDownloadSizeLimit / Self.megabyte)))
                            .tag(settings.fileDownloadSizeLimit)
                    }
                }
                .pointerStyle(.link)
            }
            Section {
                Toggle(isOn: $settings.linkPreviews) {
                    Text(Copy.linkPreviews)
                    Text(Copy.linkPreviewsHelp)
                }
                .pointerStyle(.link)
                Toggle(Copy.typingNotifications, isOn: $settings.typingNotifications)
                    .pointerStyle(.link)
                    .accessibilityIdentifier("typing-notifications")
                Toggle(isOn: $settings.readMarkersInRooms) {
                    Text(Copy.readMarkersInRooms)
                    Text(Copy.readMarkersInRoomsHelp)
                }
                .pointerStyle(.link)
                .accessibilityIdentifier("read-markers-in-rooms")
            }
        }
        .formStyle(.grouped)
        .font(.appBody)
        .accessibilityIdentifier("settings-privacy")
    }

    private static let megabyte: Int64 = 1024 * 1024
    private static let limitChoices = [1, 5, 10, 25, 100, 500]

    private static func isChoice(_ bytes: Int64) -> Bool {
        bytes == 0 || limitChoices.contains { Int64($0) * megabyte == bytes }
    }
}
