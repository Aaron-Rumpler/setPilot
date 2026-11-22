import SwiftUI

/// The home export the WiZ app gives (Settings › Export: a link valid for a short while, to a
/// JSON file): the home's signing key, its rooms, and its devices by MAC. Only what setPilot uses
/// is read; IDs are used only to put devices in rooms, and none are kept.
struct WiZHomeExport: Decodable, Sendable {
    struct Room: Decodable, Sendable {
        var room_id: Int
        var name: String
    }
    struct Device: Decodable, Sendable {
        var type: String?
        var room_id: Int?
        var name: String?
        var mac_address: String
    }
    var name: String?
    var udp_signing_key: String?
    var rooms: [Room]?
    var devices: [Device]

    static func parse(_ data: Data) -> Result<WiZHomeExport, HomeImportError> {
        do {
            let export = try JSONDecoder().decode(WiZHomeExport.self, from: data)
            return .success(export)
        } catch {
            return .failure(.notAnExport)
        }
    }
}

enum HomeImportError: Error, Equatable {
    case notAnExport
    case notALink
    case download(String)

    var message: String {
        switch self {
        case .notAnExport: "That isn't a WiZ home export (the JSON the WiZ app's export link gives)."
        case .notALink: "Paste the export link (https://…) or the JSON it gives."
        case .download(let why): "Couldn't download the export: \(why)"
        }
    }
}

/// How imported names are made.
struct HomeImportNaming: Equatable, Sendable {
    /// A room's only light is named after the room alone ("Hallway", not "Hallway - Ceiling").
    var roomOnlyWhenAlone = true
    /// The home's name first ("Home - Hallway").
    var prefixHome = false

    /// `$ROOM - $NAME`, with the options above. Nil when there's nothing to name it by.
    func name(home: String?, room: String?, device: String?, aloneInRoom: Bool) -> String? {
        let device = device?.trimmingCharacters(in: .whitespaces).nilIfEmpty
        let room = room?.trimmingCharacters(in: .whitespaces).nilIfEmpty
        var parts: [String] = []
        if prefixHome, let home = home?.trimmingCharacters(in: .whitespaces).nilIfEmpty { parts.append(home) }
        if let room { parts.append(room) }
        if let device, !(room != nil && aloneInRoom && roomOnlyWhenAlone) { parts.append(device) }
        // The home's name alone says nothing about the bulb.
        if parts.isEmpty || (parts.count == 1 && prefixHome && room == nil && device == nil) { return nil }
        return parts.joined(separator: " - ")
    }
}

/// What importing would do to one bulb, shown for review before anything changes.
struct HomeImportItem: Identifiable, Equatable, Sendable {
    /// Lower-case MAC, as setPilot keys names and signing keys.
    var mac: String
    var id: String { mac }
    var newName: String?
    var currentName: String?
    /// One of the bulbs used with setPilot.
    var known: Bool
    var include = true
}

struct HomeImportPlan: Equatable, Sendable {
    var homeName: String?
    var items: [HomeImportItem]
    /// The home's signing key, if it had a valid one (32 hex digits).
    var key: String?

    /// Lights only (the export has plugs and the like too), named per `naming`.
    init(_ export: WiZHomeExport, naming: HomeImportNaming, currentNames: [String: String], knownMACs: Set<String>) {
        homeName = export.name
        key = export.udp_signing_key.flatMap(RequestSigning.normalised)
        let rooms = Dictionary(export.rooms?.map { ($0.room_id, $0.name) } ?? [], uniquingKeysWith: { a, _ in a })
        let lights = export.devices.filter { ($0.type ?? "light") == "light" }
        var perRoom: [Int: Int] = [:]
        for d in lights { if let r = d.room_id { perRoom[r, default: 0] += 1 } }
        var seen = Set<String>()
        items = lights.compactMap { d in
            let mac = d.mac_address.lowercased().filter { $0.isHexDigit }
            guard mac.count == 12, seen.insert(mac).inserted else { return nil }
            let room = d.room_id.flatMap { rooms[$0] }
            let alone = d.room_id.map { perRoom[$0] == 1 } ?? false
            return HomeImportItem(mac: mac,
                                  newName: naming.name(home: export.name, room: room, device: d.name, aloneInRoom: alone),
                                  currentName: currentNames[mac],
                                  known: knownMACs.contains(mac))
        }
        // Bulbs used here first, then by name.
        items.sort { a, b in
            if a.known != b.known { return a.known }
            return (a.newName ?? a.mac).localizedStandardCompare(b.newName ?? b.mac) == .orderedAscending
        }
    }
}

extension String {
    fileprivate var nilIfEmpty: String? { isEmpty ? nil : self }
}

// MARK: Loading

enum HomeImportSource {
    /// Pasted text: the JSON itself, or the link to it.
    static func load(_ text: String) async -> Result<WiZHomeExport, HomeImportError> {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("{") { return WiZHomeExport.parse(Data(t.utf8)) }
        guard let url = URL(string: t), url.scheme?.lowercased() == "https", url.host != nil else {
            return .failure(.notALink)
        }
        do {
            var request = URLRequest(url: url, timeoutInterval: 20)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                // The link has a short life: an expired one is refused (403).
                return .failure(.download(http.statusCode == 403
                                          ? "the link has expired or isn't valid (make a new export in the WiZ app)"
                                          : "the server said \(http.statusCode)"))
            }
            // A home export is a few KB: anything big is something else.
            guard data.count < 1_000_000 else { return .failure(.notAnExport) }
            return WiZHomeExport.parse(data)
        } catch {
            return .failure(.download(error.localizedDescription))
        }
    }
}

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
        let keys = setKeys && plan.key != nil ? chosen.count : 0
        func count(_ n: Int, _ noun: String) -> String { "\(n) \(noun)\(n == 1 ? "" : "s")" }
        var parts = ["Named \(count(named, "bulb"))"]
        if keys > 0 { parts.append("set the signing key for \(count(keys, "bulb"))") }
        return parts.joined(separator: " and ") + "."
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
                                Text(plan.items[i].newName ?? "No name")
                                Text(detail(plan.items[i])).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                } header: {
                    Text(plan.homeName.map { "Lights in “\($0)”" } ?? "Lights")
                } footer: {
                    Text("Matched by MAC. Bulbs not used with setPilot yet keep the name and key for when they are. Room and home IDs aren't kept.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Section {
                    Button("Import") {
                        result = model.apply(plan, setKeys: setKeys && plan.key != nil)
                    }
                    .disabled(!plan.items.contains(where: \.include))
                    if let result { Text(result).foregroundStyle(.secondary) }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Import from WiZ")
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
        return "\(mac) · \(item.known ? now : "not used here yet")"
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

    /// Again with the naming options, keeping which bulbs are ticked.
    private func replan() {
        guard let export else { return }
        let excluded = Set(plan?.items.filter { !$0.include }.map(\.mac) ?? [])
        var p = HomeImportPlan(export, naming: naming, currentNames: model.names,
                               knownMACs: Set(model.knownBulbs.compactMap(\.mac)))
        for i in p.items.indices where excluded.contains(p.items[i].mac) { p.items[i].include = false }
        plan = p
    }
}
