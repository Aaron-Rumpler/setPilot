import SwiftUI

/// Choosing the bulb (typed: no network search on iPhone), naming it, its details, and settings.
struct BulbSettingsView: View {
    let model: Model
    @AppStorage(Model.addressKey) private var saved = ""
    @State private var address = ""
    @State private var name = ""
    @State private var confirmingReboot = false
    @FocusState private var focused: Bool

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
                    .disabled(address.trimmingCharacters(in: .whitespaces).isEmpty
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
                            connect()
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
                    NavigationLink("Configuration") { ConfigView(model: model) }
                        .disabled(model.link != .connected)
                    Button("Reboot…", role: .destructive) { confirmingReboot = true }
                        .disabled(model.link != .connected)
                }
            }

            Section {
                FadeSetting(model: model)
            } header: {
                Text("Fade")
            } footer: {
                Text("How long each change takes to fade in (setPilot's trans). Turning off always uses the bulb's own fade-out.")
            }

            CloudSyncSection()

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
        .confirmationDialog("Reboot the bulb?", isPresented: $confirmingReboot, titleVisibility: .visible) {
            Button("Reboot", role: .destructive) { model.reboot() }
        } message: {
            Text("It will be unreachable for a few seconds while it restarts.")
        }
    }

    private func connect() {
        let a = address.trimmingCharacters(in: .whitespaces)
        guard !a.isEmpty else { return }
        focused = false
        model.choose(a)
        name = model.currentName ?? ""
    }
}

/// The raw replies to the config requests.
struct ConfigView: View {
    let model: Model
    private let order = ["getSystemConfig", "getModelConfig", "getUserConfig", "getPower"]

    var body: some View {
        List {
            if model.info.isEmpty {
                HStack { ProgressView(); Text("Reading…").foregroundStyle(.secondary) }
            }
            ForEach(order.filter { model.info[$0] != nil }, id: \.self) { key in
                Section(key) {
                    Text(JSONHighlighter.highlight(model.info[key] ?? ""))
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                }
            }
        }
        .navigationTitle("Configuration")
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
