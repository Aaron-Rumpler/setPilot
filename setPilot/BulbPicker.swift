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
                    Text(address.isEmpty ? "Choose a bulb" : address)
                        .foregroundStyle(address.isEmpty ? .secondary : .primary)
                    if let detail = model.addressDetail {
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
        let current = address == bulb.ip || (bulb.name != nil && address == bulb.name)
        return Button {
            pick(bulb.ip)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "checkmark")
                    .font(.caption.bold())
                    .opacity(current ? 1 : 0)
                VStack(alignment: .leading, spacing: 1) {
                    Text(bulb.ip).monospacedDigit()
                    Text(bulb.name ?? "No DNS name")
                        .font(.caption)
                        .foregroundStyle(bulb.name == nil ? .tertiary : .secondary)
                }
                Spacer()
                Text(bulb.mac)
                    .font(.caption.monospaced())
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(current ? Color.accentColor.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 6))
    }

    private func useTyped() { pick(typed) }

    private func pick(_ choice: String) {
        let a = choice.trimmingCharacters(in: .whitespaces)
        guard !a.isEmpty else { return }
        model.choose(a)
        onPick()
    }
}
