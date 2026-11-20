import SwiftUI
import XippiCalls

/// The call's devices: the camera to use, and the microphone and speaker in use. Calls follow
/// the macOS default input and output (ruling R22), so those are only shown, with a way to
/// System Settings > Sound to change them.
struct DevicePicker: View {
    let coordinator: CallCoordinator

    var body: some View {
        Form {
            Section {
                CameraChoice(
                    cameras: coordinator.cameras, selected: coordinator.selectedCameraID,
                    select: { coordinator.selectCamera($0) })
            } header: {
                SectionTitle(Copy.camera)
            }
            Section {
                LabeledContent(
                    Copy.microphone, value: coordinator.audioDevices.input ?? Copy.noDevice)
                LabeledContent(
                    Copy.speaker, value: coordinator.audioDevices.output ?? Copy.noDevice)
                Button(Copy.soundSettings) { coordinator.openSoundSettings() }
                    .pointerStyle(.link)
                    .accessibilityIdentifier("call-sound-settings")
            }
        }
        .formStyle(.grouped)
        .font(.appBody)
        .frame(width: 340)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityIdentifier("call-device-picker")
        .onAppear { coordinator.refreshDevices() }
    }
}

/// The system's default camera, then each camera; picking one moves the call to it.
private struct CameraChoice: View {
    let cameras: [CameraDevice]
    let selected: String?
    let select: (String?) -> Void

    var body: some View {
        if cameras.isEmpty {
            Text(Copy.noCamera)
                .foregroundStyle(.secondary)
        } else {
            Picker(Copy.camera, selection: Binding(get: { selected }, set: { select($0) })) {
                Text(Copy.systemDefault).tag(String?.none)
                ForEach(cameras) { camera in
                    Text(camera.name).tag(Optional(camera.id))
                }
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            .pointerStyle(.link)
        }
    }
}
