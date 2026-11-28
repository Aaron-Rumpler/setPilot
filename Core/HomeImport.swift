import SwiftUI

// MARK: Applying

extension Model {
    /// Names (and, with `setKeys`, signing keys) for the included bulbs. Bulbs not used here yet
    /// keep them for when they are: both are kept by MAC.
    func apply(_ plan: HomeImportPlan, setKeys: Bool) -> String {
        let chosen = plan.items.filter(\.include)
        var named = 0
        for item in chosen {
            if let n = item.newName, n != item.currentName {
                rename(mac: item.mac, to: n)
                named += 1
            }
            if setKeys, let key = plan.key { setSigningKey(key, for: item.mac) }
        }
        // Bulbs not used here yet join Your Bulbs, without an address until one's found (on the
        // Mac by searching for the MAC; on iPhone, entered).
        var added = 0
        for item in chosen where !item.known && !knownBulbs.contains(where: { $0.mac?.lowercased() == item.mac }) {
            knownBulbs.append(KnownBulb(address: "", mac: item.mac))
            added += 1
        }
        let keys = setKeys && plan.key != nil ? chosen.count : 0
        func count(_ n: Int, _ noun: String) -> String { "\(n) \(noun)\(n == 1 ? "" : "s")" }
        // Only what happened (a zero count left out).
        var parts: [String] = []
        if named > 0 { parts.append("named \(count(named, "bulb"))") }
        if keys > 0 { parts.append("set the signing key for \(count(keys, "bulb"))") }
        if added > 0 { parts.append("added \(count(added, "bulb")) to Your Bulbs") }
        guard !parts.isEmpty else { return "Nothing was changed." }
        let text = parts.joined(separator: " and ") + "."
        return text.prefix(1).uppercased() + text.dropFirst()
    }
}

// MARK: View

/// Paste the WiZ app's home export (the link or its JSON), review what it would change, then
/// apply it.
struct HomeImportView: View {
    let model: Model
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var export: WiZHomeExport?
    @State private var plan: HomeImportPlan?
    @State private var naming = HomeImportNaming()
    @State private var setKeys = true
    @State private var loading = false
    @State private var error: String?
    @State private var result: String?
    /// Names typed in the list, by MAC: kept when the naming options change.
    @State private var edited: [String: String] = [:]

    var body: some View {
        Form {
            Section {
                TextField("Export link or JSON", text: $text, axis: .vertical)
                    .lineLimit(1...4)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                Button(loading ? "Loading…" : "Load") { Task { await load() } }
                    .disabled(loading || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if let error { Text(error).foregroundStyle(.red) }
            } footer: {
                Text("Export your home from the WiZ app: it gives a link that works for about 15 minutes. Paste the link, or the JSON it opens. Nothing changes until you choose Import below.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if let plan {
                Section("Names") {
                    Toggle("A room's only light is named after the room", isOn: $naming.roomOnlyWhenAlone)
                    Toggle("Start with the home's name", isOn: $naming.prefixHome)
                    if plan.key != nil {
                        Toggle("Set the home's signing key for these bulbs", isOn: $setKeys)
                    }
                }
                Section {
                    if plan.items.isEmpty { Text("The export has no lights.").foregroundStyle(.secondary) }
                    ForEach(plan.items.indices, id: \.self) { i in
                        Toggle(isOn: Binding(get: { self.plan?.items[i].include ?? false },
                                             set: { self.plan?.items[i].include = $0 })) {
                            VStack(alignment: .leading, spacing: 2) {
                                TextField("Name", text: Binding(get: { self.plan?.items[i].newName ?? "" }, set: { new in
                                    guard let mac = self.plan?.items[i].mac else { return }
                                    edited[mac] = new
                                    self.plan?.items[i].newName = new.isEmpty ? nil : new
                                }))
                                .accessibilityLabel("Name for \(detail(plan.items[i]))")
                                Text(detail(plan.items[i])).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                } header: {
                    Text(plan.homeName.map { "Lights in “\($0)”" } ?? "Lights")
                } footer: {
                    Text("Matched by MAC. Names can be changed here first. Bulbs not used with setPilot yet join Your Bulbs, with their name and key, until their address is found. Room and home IDs aren't kept.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Section {
                    Button("Import") {
                        result = model.apply(plan, setKeys: setKeys && plan.key != nil)
                        replan() // the names (and keys) are the current ones now
                    }
                    .disabled(!plan.items.contains(where: \.include))
                    if let result { Text(result).foregroundStyle(.secondary) }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Import from the WiZ App")
        .onChange(of: naming) { replan() }
        #if os(macOS)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } // a sheet there
        }
        #endif
    }

    private func detail(_ item: HomeImportItem) -> String {
        let mac = stride(from: 0, to: item.mac.count, by: 2).map { i in
            let s = item.mac.index(item.mac.startIndex, offsetBy: i)
            return String(item.mac[s..<item.mac.index(s, offsetBy: 2)])
        }.joined(separator: ":")
        let now = item.currentName.map { "now “\($0)”" } ?? "no name yet"
        let key = item.otherKey && setKeys ? " · replaces its signing key" : ""
        return "\(mac) · \(item.known ? now : "not used here yet")\(key)"
    }

    private func load() async {
        loading = true
        error = nil
        result = nil
        defer { loading = false }
        switch await HomeImportSource.load(text) {
        case .success(let e):
            export = e
            replan()
        case .failure(let e):
            error = e.message
            export = nil
            plan = nil
        }
    }

    /// The signing keys the export's bulbs have now, by lower-case MAC.
    private func currentKeys(_ export: WiZHomeExport) -> [String: String] {
        var keys: [String: String] = [:]
        for d in export.devices {
            let mac = (d.mac_address ?? "").lowercased().filter { $0.isHexDigit }
            if let key = model.signingKey(for: mac) { keys[mac] = key }
        }
        return keys
    }

    /// Again with the naming options, keeping which bulbs are ticked.
    private func replan() {
        guard let export else { return }
        let excluded = Set(plan?.items.filter { !$0.include }.map(\.mac) ?? [])
        var p = HomeImportPlan(export, naming: naming, currentNames: model.names,
                               knownMACs: Set(model.knownBulbs.compactMap(\.mac)),
                               currentKeys: currentKeys(export))
        for i in p.items.indices {
            if excluded.contains(p.items[i].mac) { p.items[i].include = false }
            if let name = edited[p.items[i].mac] { p.items[i].newName = name.isEmpty ? nil : name }
        }
        plan = p
    }
}
