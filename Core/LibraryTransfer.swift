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
}

extension Library {
    /// The file with the items already here given new IDs and names of their own; presets of a
    /// copied scene or scale follow it to the copy.
    fileprivate func copiesOfClashes(_ original: LibraryFile) -> LibraryFile {
        var file = original
        var newIDs: [UUID: UUID] = [:]
        let sceneIDs = Set(customScenes.map(\.id))
        let scaleIDs = Set(cctScales.values.flatMap { $0.map(\.id) })
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

    var exportFile: LibraryFile { LibraryFile(presets: presets, customScenes: customScenes, cctScales: cctScales) }

    /// What to do with an incoming item that's already here (the same ID: the same item, shared
    /// or exported before).
    enum Clash { case replace, keepBoth, skip }

    /// How many of `file`'s items are already here.
    func clashes(_ file: LibraryFile) -> Int {
        let p = Set(presets.map(\.id)), s = Set(customScenes.map(\.id))
        let c = Set(cctScales.values.flatMap { $0.map(\.id) })
        return file.presets.filter { p.contains($0.id) }.count + file.customScenes.filter { s.contains($0.id) }.count
            + file.cctScales.values.flatMap { $0 }.filter { c.contains($0.id) }.count
    }

    /// Adds what's in `file`, keeping everything else; an item that's already here is replaced, or
    /// added again as a copy (a new ID, and a name of its own), or left as it is. Returns what
    /// changed, as a sentence.
    func merge(_ file: LibraryFile, clash: Clash = .replace) -> String {
        var file = file
        if clash == .keepBoth { file = copiesOfClashes(file) }
        // A shared preset carries no favourite (it's the sender's): one replacing yours keeps yours.
        for i in file.presets.indices where file.presets[i].favourite == nil {
            file.presets[i].favourite = presets.first { $0.id == file.presets[i].id }?.favourite
        }
        func merged<T: Identifiable>(_ mine: [T], _ theirs: [T]) -> [T] {
            var out = mine
            for item in theirs {
                if let i = out.firstIndex(where: { $0.id == item.id }) {
                    if clash == .replace { out[i] = item }
                } else {
                    out.append(item)
                }
            }
            return out
        }
        presets = merged(presets, file.presets)
        customScenes = merged(customScenes, file.customScenes)
        var scales = cctScales
        for (mac, list) in file.cctScales { scales[mac.lowercased()] = merged(scales[mac.lowercased()] ?? [], list) }
        cctScales = scales
        let scaleCount = file.cctScales.values.reduce(0) { $0 + $1.count }
        func count(_ n: Int, _ noun: String) -> String { "\(n) \(noun)\(n == 1 ? "" : "s")" }
        return "Imported \(count(file.presets.count, "preset")), \(count(file.customScenes.count, "custom scene")) and \(count(scaleCount, "CCT scale"))."
    }
}

struct LibraryDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.json]
    var file: LibraryFile

    init(file: LibraryFile) { self.file = file }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
        file = try JSONDecoder().decode(LibraryFile.self, from: data)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return FileWrapper(regularFileWithContents: try encoder.encode(file))
    }
}

/// Settings section: export the library to a file, or import one (merged in).
struct LibraryTransferSection: View {
    let model: Model
    @State private var exporting = false
    @State private var importing = false
    @State private var result: String?
    @State private var shownResult = ""

    var body: some View {
        Section {
            HStack {
                Button("Export…") { exporting = true }
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
        .fileExporter(isPresented: $exporting, document: LibraryDocument(file: model.library.exportFile),
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
            let file = try JSONDecoder().decode(LibraryFile.self, from: Data(contentsOf: url))
            // A later format may mean something else by the same keys: don't guess.
            guard file.setPilotLibrary <= 1 else {
                result = "That library file is from a newer version of setPilot."
                return
            }
            // Items already here: asked about first (IncomingItems).
            if model.library.clashes(file) > 0 {
                IncomingItems.shared.pending = file
                #if os(macOS)
                HandoffRouter.shared.open(.controls) // the main window asks
                #endif
            } else {
                result = model.library.merge(file)
            }
        } catch is DecodingError {
            result = "That isn't a setPilot library file."
        } catch {
            result = "Couldn't import: \(error.localizedDescription)"
        }
    }
}
