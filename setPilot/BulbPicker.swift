import SwiftUI

/// Shows the chosen bulb; opening it searches the network and lists what answers (IP and DNS
/// name), with a field for typing an IP address or DNS name. Only an explicit choice changes the
/// saved bulb.
struct BulbPicker: View {
    let model: Model
    @AppStorage(Model.addressKey) private var address = ""
    @State private var open = false

    var body: some View {
        Button {
            open.toggle()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "lightbulb")
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(model.currentName ?? (address.isEmpty ? "Choose a bulb" : address))
                        .foregroundStyle(address.isEmpty ? .secondary : .primary)
                    let detail = model.currentName != nil
                        ? [address, model.addressDetail].compactMap { $0 }.joined(separator: " · ")
                        : model.addressDetail
                    if let detail, !detail.isEmpty {
                        Text(detail).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .help("Choose the bulb: searches your network, or type an address")
        .popover(isPresented: $open, arrowEdge: .bottom) {
            BulbChooser(model: model) { open = false }
        }
    }
}

/// The picker's dropdown: searches when it appears, lists the bulbs that answer (IP, DNS name,
/// MAC) with the current one ticked, and takes a typed IP address or DNS name.
struct BulbChooser: View {
    let model: Model
    var onPick: () -> Void = {}
    @AppStorage(Model.addressKey) private var address = ""
    @State private var typed = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Bulbs on your network").font(.headline)
                Spacer()
                if model.discovering {
                    ProgressView().controlSize(.small)
                } else {
                    Button {
                        Task { await model.discover() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .help("Search again")
                }
            }

            if model.discovered.isEmpty {
                Text(model.discovering ? "Searching…" : (model.discoveryNote ?? "No bulbs found"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(spacing: 2) {
                    ForEach(model.discovered) { bulb in row(bulb) }
                }
            }

            Divider()

            HStack(spacing: 8) {
                TextField("IP address or DNS name", text: $typed)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(useTyped)
                Button("Connect", action: useTyped)
                    .disabled(typed.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(14)
        .frame(width: 360)
        .onAppear {
            typed = ""
            Task { await model.discover() }
        }
    }

    private func row(_ bulb: DiscoveredBulb) -> some View {
        let current = model.chosenMAC.map { $0 == bulb.mac.lowercased() }
            ?? (address == bulb.ip || (bulb.name != nil && address == bulb.name))
        let name = model.name(for: bulb.mac)
        let detail = name != nil
            ? [bulb.ip, bulb.name].compactMap { $0 }.joined(separator: " · ")
            : (bulb.name ?? "No DNS name")
        return HStack(spacing: 6) {
            Button {
                pick(bulb.ip, mac: bulb.mac)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark")
                        .font(.caption.bold())
                        .opacity(current ? 1 : 0)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(name ?? bulb.ip).monospacedDigit()
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(name == nil && bulb.name == nil ? .tertiary : .secondary)
                    }
                    Spacer()
                    Text(bulb.mac)
                        .font(.caption.monospaced())
                        .foregroundStyle(.tertiary)
                }
                .padding(.vertical, 4)
                .padding(.leading, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            RenameButton(model: model, mac: bulb.mac)
                .padding(.trailing, 6)
        }
        .background(current ? Color.accentColor.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 6))
    }

    private func useTyped() { pick(typed, mac: nil) }

    private func pick(_ choice: String, mac: String?) {
        let a = choice.trimmingCharacters(in: .whitespaces)
        guard !a.isEmpty else { return }
        model.choose(a, mac: mac)
        onPick()
    }
}

/// A pencil button that names a bulb (by MAC). Names are kept on this Mac.
struct RenameButton: View {
    let model: Model
    let mac: String
    @State private var editing = false
    @State private var draft = ""

    var body: some View {
        Button {
            draft = model.name(for: mac) ?? ""
            editing = true
        } label: {
            Image(systemName: "pencil")
        }
        .buttonStyle(.borderless)
        .help("Name this bulb")
        .alert("Name this bulb", isPresented: $editing) {
            TextField("Name", text: $draft)
            Button("Save") { model.rename(mac: mac, to: draft) }
            if model.name(for: mac) != nil {
                Button("Remove Name", role: .destructive) { model.rename(mac: mac, to: "") }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("MAC address \(mac). The name is kept on this Mac.")
        }
    }
}
