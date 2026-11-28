import CryptoKit
import SwiftUI
import UniformTypeIdentifiers

/// Presets, custom scenes and CCT scales as one JSON file, to move them between devices without
/// iCloud (which needs a paid account).
struct LibraryFile: Codable, Sendable {
    /// Marks the file as setPilot's, and its format.
    var setPilotLibrary = 1
    var presets: [Preset]
    var customScenes: [CustomScene]
    /// Per bulb, keyed by lower-case MAC.
    var cctScales: [String: [CCTScale]]
    /// Each item as it was in the file read, by place: a newer build's fields are taken from it
    /// when it's merged (Library.takeExtras). Not written.
    var raw: Raw?

    struct Raw: Sendable {
        var presets: [Data] = []
        var customScenes: [Data] = []
        var cctScales: [String: [Data]] = [:]
    }

    private enum CodingKeys: String, CodingKey { case setPilotLibrary, presets, customScenes, cctScales }

    /// The file in `data`, with each item's JSON as it came (`raw`); nil if it won't decode.
    static func read(_ data: Data) -> LibraryFile? {
        guard var file = try? JSONDecoder().decode(LibraryFile.self, from: data) else { return nil }
        if let top = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            // In the order decoded, so each is found by its item's place.
            func items(_ value: Any?) -> [Data] {
                (value as? [Any] ?? []).map {
                    JSONSerialization.isValidJSONObject($0) ? (try? JSONSerialization.data(withJSONObject: $0)) ?? Data() : Data()
                }
            }
            var raw = Raw(presets: items(top["presets"]), customScenes: items(top["customScenes"]))
            for (mac, list) in top["cctScales"] as? [String: Any] ?? [:] { raw.cctScales[mac] = items(list) }
            file.raw = raw
        }
        return file
    }

    /// The format a file says it's in, read on its own: a newer file may not decode as this one.
    /// Any number (2.5 is newer too), but not true (an NSNumber as well, told apart by CF's type).
    static func format(of data: Data) -> Double? {
        guard let n = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["setPilotLibrary"] as? NSNumber,
              CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
        return n.doubleValue
    }

    /// "2 presets and 1 CCT scale": zero counts left out.
    static func counted(presets: Int, scenes: Int, scales: Int) -> String {
        func count(_ n: Int, _ noun: String) -> String { "\(n) \(noun)\(n == 1 ? "" : "s")" }
        let parts = [(presets, "preset"), (scenes, "custom scene"), (scales, "CCT scale")].filter { $0.0 > 0 }.map { count($0.0, $0.1) }
        guard let last = parts.last else { return "" }
        return parts.count == 1 ? last : parts.dropLast().joined(separator: ", ") + " and " + last
    }
}

extension Library {
    /// The file with the items already here given new IDs and names of their own; presets of a
    /// copied scene or scale follow it to the copy.
    fileprivate func copiesOfClashes(_ original: LibraryFile) -> LibraryFile {
        var file = original
        var newIDs: [UUID: UUID] = [:]
        let sceneIDs = Set(customScenes.map(\.id))
        // Names here and in the file, and the copies' as they're given, so no two end up the same.
        var sceneNames = customScenes.map(\.name) + file.customScenes.map(\.name)
        for i in file.customScenes.indices where sceneIDs.contains(file.customScenes[i].id) {
            let new = UUID()
            newIDs[file.customScenes[i].id] = new
            file.customScenes[i].id = new
            file.customScenes[i].name = unique(file.customScenes[i].name, in: sceneNames)
            sceneNames.append(file.customScenes[i].name)
        }
        for (mac, list) in file.cctScales {
            var copied = list
            var names = scales(for: mac).map(\.name) + list.map(\.name)
            // Per bulb, as they're merged.
            let scaleIDs = Set(scales(for: mac).map(\.id))
            for i in copied.indices where scaleIDs.contains(copied[i].id) {
                let new = UUID()
                newIDs[copied[i].id] = new
                copied[i].id = new
                copied[i].name = unique(copied[i].name, in: names)
                names.append(copied[i].name)
            }
            file.cctScales[mac] = copied
        }
        let presetIDs = Set(presets.map(\.id))
        var presetNames = presets.map(\.name) + file.presets.map(\.name)
        for i in file.presets.indices {
            switch file.presets[i].colour {
            case let .custom(id, speed): if let n = newIDs[id] { file.presets[i].colour = .custom(n, speed: speed) }
            case let .customCCT(id, k): if let n = newIDs[id] { file.presets[i].colour = .customCCT(scale: n, kelvin: k) }
            default: break
            }
            if presetIDs.contains(file.presets[i].id) {
                file.presets[i].id = UUID()
                file.presets[i].name = unique(file.presets[i].name, in: presetNames)
                presetNames.append(file.presets[i].name)
            }
        }
        return file
    }

    /// An ID made from another and a bulb's MAC, the same every time (name-based, version 5 style).
    fileprivate static func bulbsOwnID(_ id: UUID, _ mac: String) -> UUID {
        var bytes = Array(SHA256.hash(data: Data((id.uuidString + "/" + mac.lowercased()).utf8)).prefix(16))
        bytes[6] = bytes[6] & 0x0F | 0x50
        bytes[8] = bytes[8] & 0x3F | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    var exportFile: LibraryFile { LibraryFile(presets: presets, customScenes: customScenes, cctScales: cctScales) }

    /// The whole library as a file to export, with a newer build's fields kept (`encoded`).
    var exportData: Data { encoded(exportFile, pretty: true) ?? Data() }

    /// What to do with an incoming item that's already here (the same ID: the same item, shared
    /// or exported before).
    enum Clash { case replace, keepBoth, skip }

    /// How many of `file`'s items are already here.
    func clashes(_ original: LibraryFile) -> Int {
        let file = scalesOfOtherBulbsRenumbered(original) // as they'll be merged
        let p = Set(presets.map(\.id)), s = Set(customScenes.map(\.id))
        // Scales per bulb, as they're merged.
        let scaleClashes = file.cctScales.reduce(0) { n, entry in
            let here = Set(scales(for: entry.key).map(\.id))
            return n + entry.value.filter { here.contains($0.id) }.count
        }
        return file.presets.filter { p.contains($0.id) }.count + file.customScenes.filter { s.contains($0.id) }.count + scaleClashes
    }

    /// The file with scales that have the ID of one here for another bulb given IDs of their own
    /// for this bulb (their presets follow), so no two bulbs' scales share one (a preset would
    /// find either). The same each time (from the ID and the bulb), so importing it again finds
    /// the copy rather than making another; named apart from that bulb's other scales.
    fileprivate func scalesOfOtherBulbsRenumbered(_ original: LibraryFile) -> LibraryFile {
        var file = original
        var newIDs: [UUID: UUID] = [:]
        for (mac, list) in file.cctScales {
            let elsewhere = Set(cctScales.filter { $0.key != mac.lowercased() }.values.flatMap { $0.map(\.id) })
            let here = scales(for: mac)
            // This bulb's, and the file's others for it (not the one being named).
            var names = here.map(\.name)
            var others = list.map(\.name)
            var renumbered = list
            for i in renumbered.indices where elsewhere.contains(renumbered[i].id) {
                var taken = names
                taken += others.enumerated().filter { $0.offset != i }.map(\.element)
                let new = Self.bulbsOwnID(renumbered[i].id, mac)
                newIDs[renumbered[i].id] = new
                renumbered[i].id = new
                // Its earlier copy's name (it's replaced, or kept); a new one gets its own.
                if let copy = here.first(where: { $0.id == new }) {
                    renumbered[i].name = copy.name
                } else {
                    renumbered[i].name = unique(renumbered[i].name, in: taken)
                }
                names.append(renumbered[i].name)
                others[i] = renumbered[i].name
            }
            file.cctScales[mac] = renumbered
        }
        guard !newIDs.isEmpty else { return file }
        for i in file.presets.indices {
            if case let .customCCT(id, k) = file.presets[i].colour, let n = newIDs[id] {
                file.presets[i].colour = .customCCT(scale: n, kelvin: k)
            }
        }
        return file
    }

    /// Adds what's in `file`, keeping everything else; an item that's already here is replaced, or
    /// added again as a copy (a new ID, and a name of its own), or left as it is. Returns what
    /// changed, as a sentence starting with `verb` (with no full stop, for a status line).
    func merge(_ file: LibraryFile, clash: Clash = .replace, verb: String = "Imported") -> String {
        var file = scalesOfOtherBulbsRenumbered(file)
        if clash == .keepBoth { file = copiesOfClashes(file) }
        // A shared preset carries no favourite (it's the sender's): one replacing yours keeps yours.
        for i in file.presets.indices where file.presets[i].favourite == nil {
            file.presets[i].favourite = presets.first { $0.id == file.presets[i].id }?.favourite
        }
        var taken = 0 // what was actually added or replaced, per kind as it's merged
        // `raw`: each incoming item's JSON, by place (the file's items keep theirs through the
        // renumbering above), for the newer-build fields it brings.
        func merged<T: Identifiable & Encodable>(_ mine: [T], _ theirs: [T], raw: [Data]?) -> [T] where T.ID == UUID {
            var out = mine
            taken = 0
            for (n, item) in theirs.enumerated() {
                let data: Data? = raw.flatMap { n < $0.count ? $0[n] : nil }
                if let i = out.firstIndex(where: { $0.id == item.id }) {
                    if clash == .replace {
                        out[i] = item
                        takeExtras(data, of: item) // its own, not those of the copy replaced
                        taken += 1
                    }
                } else {
                    out.append(item)
                    takeExtras(data, of: item)
                    taken += 1
                }
            }
            return out
        }
        presets = merged(presets, file.presets, raw: file.raw?.presets)
        let presetCount = taken
        customScenes = merged(customScenes, file.customScenes, raw: file.raw?.customScenes)
        let sceneCount = taken
        var scales = cctScales
        var scaleCount = 0
        var scalesAside = 0 // for bulbs whose stored scales are kept raw, or all while unreadable
        for (mac, list) in file.cctScales {
            scales[mac.lowercased()] = merged(scales[mac.lowercased()] ?? [], list, raw: file.raw?.cctScales[mac])
            scaleCount += taken
            if !canEdit(Self.cctScalesKey) || rawScaleMACs.contains(mac.lowercased()) { scalesAside += taken }
        }
        cctScales = scales
        guard presetCount + sceneCount + scaleCount > 0 else { return "Nothing new to add: you already have all of these" }
        let text = "\(verb) \(LibraryFile.counted(presets: presetCount, scenes: sceneCount, scales: scaleCount))"
        // Kept aside, where a newer build's data can't take them: not synced yet (nor editable,
        // while a whole list is unreadable).
        let aside = [(canEdit(Self.presetsKey) ? 0 : presetCount, "preset"),
                     (canEdit(Self.customScenesKey) ? 0 : sceneCount, "custom scene"),
                     (scalesAside, "CCT scale")].filter { $0.0 > 0 }
        guard !aside.isEmpty else { return text }
        let one = aside.count == 1 && aside[0].0 == 1
        let nouns = aside.map { one ? $0.1 : $0.1 + "s" }
        let what = nouns.count == 1 ? nouns[0] : nouns.dropLast().joined(separator: ", ") + " and " + nouns[nouns.count - 1]
        return text + "; the \(what) \(one ? "is" : "are") kept aside on this device and not synced until setPilot is updated here (a newer version saved what's here)"
    }
}

struct LibraryDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.json]
    /// The file as JSON, made by the library (Library.exportData), with a newer build's fields.
    var data: Data

    init(data: Data) { self.data = data }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents, LibraryFile.read(data) != nil else { throw CocoaError(.fileReadCorruptFile) }
        self.data = data
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

/// Settings section: export the library to a file, or import one (merged in).
struct LibraryTransferSection: View {
    let model: Model
    @State private var exporting = false
    /// Made when Export is chosen, not at every redraw.
    @State private var document: LibraryDocument?
    @State private var importing = false
    @State private var result: String?
    @State private var shownResult = ""

    var body: some View {
        Section {
            HStack {
                Button("Export…") {
                    document = LibraryDocument(data: model.library.exportData)
                    exporting = true
                }
                Button("Import…") { importing = true }
            }
        } header: {
            Text("Presets, Scenes and Scales")
        } footer: {
            Text("A JSON file with your presets, custom scenes and CCT scales, to copy them between your Mac and iPhone. Importing adds to what's here; for items already here (exported from here before, say), it asks whether to replace them, keep both, or skip them.")
                #if os(macOS)
                .font(.callout)
                .foregroundStyle(.secondary)
                #endif
        }
        .fileExporter(isPresented: $exporting, document: document,
                      contentType: .json, defaultFilename: "setPilot Library") { outcome in
            if case .failure(let error) = outcome { result = "Couldn't export: \(error.localizedDescription)" }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { outcome in
            switch outcome {
            case .success(let url): importFile(url)
            case .failure(let error): result = "Couldn't import: \(error.localizedDescription)"
            }
        }
        .startsInCloudFolder()
        // The text kept while the alert closes (result is cleared first).
        .onChange(of: result) { _, text in if let text { shownResult = text } }
        .alert(result ?? shownResult, isPresented: Binding(get: { result != nil }, set: { if !$0 { result = nil } })) {
            Button("OK") { result = nil }
        }
    }

    private func importFile(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            // A later format may mean something else by the same keys: don't guess. Read first,
            // since a newer file may not decode here at all.
            let format = LibraryFile.format(of: data)
            if let format, format > 1 {
                result = "That library file is from a newer version of setPilot. Update setPilot here to import it."
                return
            }
            guard let file = LibraryFile.read(data) else {
                // setPilot's, but not readable here: likely newer (a colour this version lacks, say).
                result = format != nil
                    ? "That library file couldn't be read: it may be from a newer version of setPilot. Update setPilot here to import it."
                    : "That isn't a setPilot library file."
                return
            }
            guard !file.presets.isEmpty || !file.customScenes.isEmpty || file.cctScales.values.contains(where: { !$0.isEmpty }) else {
                result = "There's nothing in that file to add."
                return
            }
            // Items already here: asked about first (IncomingItems).
            // (After any other still being asked about; the main window asks, opened for it on the Mac.)
            if model.library.clashes(file) > 0 {
                IncomingItems.shared.offer(file, imported: true)
            } else {
                result = model.library.merge(file) + "." // a sentence here, in an alert
            }
        } catch {
            result = "Couldn't import: \(error.localizedDescription)"
        }
    }
}
