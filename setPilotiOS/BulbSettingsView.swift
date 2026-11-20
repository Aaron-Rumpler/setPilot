import SwiftUI

/// Choosing the bulb (typed: no network search on iPhone), naming it, its details, and settings.
struct BulbSettingsView: View {
    let model: Model
    @AppStorage(Model.addressKey) private var saved = ""
    @State private var address = ""
    @State private var name = ""
    @FocusState private var focused: Bool
    @AppStorage(Stepping.snapKey) private var snaps = true

    var body: some View {
        Form {
            Section {
                TextField("IP address or DNS name", text: $address)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($focused)
                    .submitLabel(.go)
                    .onSubmit(connect)
                Button(saved.isEmpty ? "Connect" : "Connect to This Bulb", action: connect)
                    .disabled(address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                              || (address == saved && model.link == .connected))
            } header: {
                Text("Bulb")
            } footer: {
                Text("setPilot doesn't search your network on iPhone. Enter the bulb's IP address (the Mac app and your router show it) or its DNS name. A name keeps working if the bulb's address changes.")
            }

            if model.knownBulbs.count > 1 || (model.knownBulbs.first.map { $0.address != saved } ?? false) {
                Section {
                    ForEach(model.namedBulbs) { bulb in
                        Button {
                            address = bulb.address
                            // With its MAC, so a different bulb that now has the address isn't used.
                            use(bulb.address, mac: bulb.mac)
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(bulb.name ?? bulb.address).foregroundStyle(.primary)
                                    if bulb.name != nil {
                                        Text(bulb.address).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                if bulb.address == saved { Image(systemName: "checkmark").foregroundStyle(.tint) }
                            }
                        }
                        .swipeActions {
                            Button("Forget", role: .destructive) { model.forgetBulb(bulb) }
                        }
                    }
                } header: {
                    Text("Your Bulbs")
                } footer: {
                    Text("Bulbs you've used. Tap one to switch to it; the watch can switch too.")
                }
            }

            if !saved.isEmpty {
                Section("Status") {
                    LabeledContent("Connection") {
                        HStack(spacing: 6) {
                            Circle().fill(model.linkColour).frame(width: 8, height: 8)
                            Text(model.linkText)
                        }
                    }
                    if let detail = model.addressDetail { LabeledContent("Also known as", value: detail) }
                    LabeledContent("Live updates") {
                        Text(!model.live ? "Off" : model.pushSeen ? "On" : "On (none yet)")
                    }
                    if !model.liveStatus.isEmpty {
                        Text(model.liveStatus).font(.footnote).foregroundStyle(.secondary)
                    }
                }

                Section("Device") {
                    if let mac = model.chosenMAC {
                        LabeledContent("Name") {
                            TextField("Name", text: $name, prompt: Text("None"))
                                .multilineTextAlignment(.trailing)
                                .submitLabel(.done)
                                .onSubmit { model.rename(mac: mac, to: name) }
                                .onChange(of: name) { _, new in model.rename(mac: mac, to: new) }
                        }
                    }
                    LabeledContent("MAC address", value: model.mac ?? "—")
                    LabeledContent("Module", value: model.module ?? "—")
                    LabeledContent("Firmware", value: model.firmware ?? "—")
                    if let mac = model.chosenMAC {
                        NavigationLink {
                            SigningKeyView(model: model, mac: mac)
                        } label: {
                            LabeledContent("Signing", value: model.signingStatus)
                        }
                    }
                    NavigationLink("Device Info") { ConfigView(model: model) }
                        .disabled(model.link != .connected)
                    NavigationLink("Console") { ConsoleView(model: model) }
                }
            }

            Section {
                Toggle("Snap Sliders to Round Numbers", isOn: $snaps)
                    // The watch's Crown follows this: pass it on (as for a change to the presets).
                    .onChange(of: snaps) { model.library.onChange?() }
            } header: {
                Text("Sliders")
            } footer: {
                Text("Steps of 5 for dimming, 50 K for temperatures, 32 for colour channels. Touch and hold a slider for a moment before dragging to move it in 1s anyway, or tap a value to type it or fine-tune it.")
            }

            Section {
                FadeSetting(model: model)
            } header: {
                Text("Fade")
            } footer: {
                Text("The fade (setPilot's trans) that the controls' Fade and Compose offer as the default. Turning off always uses the bulb's own fade-out.")
            }

            CloudSyncSection()
            LibraryTransferSection(model: model)

            Section {
                NavigationLink("Shortcuts and Siri") { ShortcutsHelpView() }
            }
        }
        .navigationTitle("Bulb & Settings")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            address = saved
            name = model.currentName ?? ""
            if saved.isEmpty { focused = true }
        }
        // A typed address's MAC (and so its name) is only known once the bulb answers.
        .onChange(of: model.chosenMAC) { name = model.currentName ?? "" }
    }

    private func connect() { use(address, mac: nil) }

    private func use(_ typedAddress: String, mac: String?) {
        let a = typedAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !a.isEmpty else { return }
        focused = false
        model.choose(a, mac: mac)
        name = model.currentName ?? ""
    }
}

/// The chosen bulb's signing key, for firmware that wants signed requests.
struct SigningKeyView: View {
    let model: Model
    let mac: String
    @State private var draft = ""
    @Environment(\.dismiss) private var dismiss

    private var valid: Bool {
        draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || RequestSigning.normalised(draft) != nil
    }

    var body: some View {
        Form {
            Section {
                TextField("32 hex digits", text: $draft, axis: .vertical)
                    .font(.body.monospaced())
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.done)
            } footer: {
                if !valid {
                    Text("A signing key is 32 hex digits (0–9 and a–f).").foregroundStyle(.red)
                } else {
                    Text(SigningHelp.text)
                }
            }
            if model.signingKey(for: mac) != nil {
                Section {
                    Button("Remove Key", role: .destructive) {
                        model.setSigningKey(nil, for: mac)
                        dismiss()
                    }
                }
            }
        }
        .navigationTitle("Signing Key")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    if model.setSigningKey(draft, for: mac) { dismiss() }
                }
                .disabled(!valid)
            }
        }
        .onAppear { draft = model.signingKey(for: mac) ?? "" }
    }
}

/// Every read the bulb answers, as it sent them.
struct ConfigView: View {
    let model: Model

    var body: some View {
        ScrollView {
            DeviceInfoView(model: model).padding()
        }
        .navigationTitle("Device Info")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { model.readConfig() }
    }
}

struct ShortcutsHelpView: View {
    var body: some View {
        List {
            Section {
                Text("setPilot's actions are in the Shortcuts app: apply a preset, switch the bulb on or off, set or change its brightness. Use them from Siri, the Action button, or Control Center and the Lock Screen (add a Shortcuts control and pick the action).")
            }
            Section("Siri phrases") {
                Text("“Apply a preset in setPilot”")
                Text("“Turn on the light with setPilot”")
                Text("“Make it brighter with setPilot”")
            }
        }
        .navigationTitle("Shortcuts and Siri")
        .navigationBarTitleDisplayMode(.inline)
    }
}
