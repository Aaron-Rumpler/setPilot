import Foundation

/// The home export the WiZ app gives (Settings › Export: a link valid for a short while, to a
/// JSON file): the home's signing key, its rooms, and its devices by MAC. Only what setPilot uses
/// is read; IDs are used only to put devices in rooms, and none are kept.
struct WiZHomeExport: Decodable, Sendable {
    // Everything optional: one odd entry (a remote, a group) mustn't make the whole export unreadable.
    struct Room: Decodable, Sendable {
        var room_id: Int?
        var name: String?
    }
    struct Device: Decodable, Sendable {
        var type: String?
        var room_id: Int?
        var name: String?
        var mac_address: String?
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
    /// It has a signing key already, not the home's: importing the key replaces it.
    var otherKey = false
    var include = true
}

struct HomeImportPlan: Equatable, Sendable {
    var homeName: String?
    var items: [HomeImportItem]
    /// The home's signing key, if it had a valid one (32 hex digits).
    var key: String?

    /// Lights only (the export has plugs and the like too), named per `naming`.
    init(_ export: WiZHomeExport, naming: HomeImportNaming, currentNames: [String: String], knownMACs: Set<String>,
         currentKeys: [String: String] = [:]) {
        homeName = export.name
        let homeKey = export.udp_signing_key.flatMap(RequestSigning.normalised)
        key = homeKey
        let rooms = Dictionary((export.rooms ?? []).compactMap { r in r.room_id.flatMap { id in r.name.map { (id, $0) } } },
                               uniquingKeysWith: { a, _ in a })
        let lights = export.devices.filter { ($0.type ?? "light") == "light" }
        var perRoom: [Int: Int] = [:]
        for d in lights { if let r = d.room_id { perRoom[r, default: 0] += 1 } }
        var seen = Set<String>()
        items = lights.compactMap { d in
            let mac = (d.mac_address ?? "").lowercased().filter { $0.isHexDigit }
            guard mac.count == 12, seen.insert(mac).inserted else { return nil }
            let room = d.room_id.flatMap { rooms[$0] }
            let alone = d.room_id.map { perRoom[$0] == 1 } ?? false
            return HomeImportItem(mac: mac,
                                  newName: naming.name(home: export.name, room: room, device: d.name, aloneInRoom: alone),
                                  currentName: currentNames[mac],
                                  known: knownMACs.contains(mac),
                                  otherKey: currentKeys[mac].map { $0 != homeKey } ?? false)
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
