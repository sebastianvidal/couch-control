import SwiftUI

/// Lets the user decide what each controller control does on the computer.
struct ControllerBindingsView: View {
    @ObservedObject var controller: ControllerBridge

    var body: some View {
        List {
            PresetSection(controller: controller)
            ForEach(Control.sections, id: \.0) { title, controls in
                Section(title) {
                    ForEach(controls) { control in
                        ControlRow(controller: controller, control: control)
                    }
                }
            }
        }
        .navigationTitle("Controller bindings")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct PresetSection: View {
    @ObservedObject var controller: ControllerBridge

    var body: some View {
        Section {
            Menu {
                ForEach(ControllerProfile.presets, id: \.name) { preset in
                    Button(preset.name) { controller.profile = preset }
                }
            } label: {
                HStack {
                    Text("Preset")
                    Spacer()
                    Text(controller.profile.name).foregroundStyle(.secondary)
                    Image(systemName: "chevron.up.chevron.down").font(.caption).foregroundStyle(.secondary)
                }
            }
            Text("Pick a preset, then change any control below. Changes apply immediately.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }
}

private struct ControlRow: View {
    @ObservedObject var controller: ControllerBridge
    let control: Control

    var body: some View {
        NavigationLink {
            ActionPicker(control: control, current: controller.profile[control]) { action in
                var profile = controller.profile
                profile[control] = action
                if ControllerProfile.presets.contains(where: { $0.name == profile.name }) {
                    profile.name = "Custom"
                }
                controller.profile = profile
            }
        } label: {
            HStack {
                Text(control.label)
                Spacer()
                Text(controller.profile[control].label).foregroundStyle(.secondary)
            }
        }
    }
}

private struct ActionPicker: View {
    let control: Control
    let current: ControlAction
    let onPick: (ControlAction) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            Section {
                row(.none, "Nothing")
                if control == .rightStick { row(.mouseLook, "Mouse look") }
                row(.mouseLeft, "Left click")
                row(.mouseRight, "Right click")
            }
            ForEach(KeyCatalog.groups, id: \.0) { title, keys in
                Section(title) {
                    ForEach(keys, id: \.1) { name, code in
                        row(.key(code), name)
                    }
                }
            }
        }
        .navigationTitle(control.label)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func row(_ action: ControlAction, _ label: String) -> some View {
        Button {
            onPick(action)
            dismiss()
        } label: {
            HStack {
                Text(label).foregroundStyle(.primary)
                Spacer()
                if current == action {
                    Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
                }
            }
        }
    }
}
