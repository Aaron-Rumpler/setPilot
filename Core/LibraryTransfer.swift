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
    var exportFile: LibraryFile { LibraryFile(presets: presets, customScenes: customScenes, cctScales: cctScales) }

    /// Adds what's in `file`, replacing items with the same ID (the same item exported earlier)
    /// and keeping everything else. Returns what changed, as a sentence.
    func merge(_ file: LibraryFile) -> String {
        func merged<T: Identifiable>(_ mine: [T], _ theirs: [T]) -> [T] {
            var out = mine
            for item in theirs {
                if let i = out.firstIndex(where: { $0.id == item.id }) { out[i] = item } else { out.append(item) }
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
            Text("A JSON file with your presets, custom scenes and CCT scales, to copy them between your Mac and iPhone. Importing adds to what's here; items exported from here before are updated.")
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
            result = model.library.merge(file)
        } catch is DecodingError {
            result = "That isn't a setPilot library file."
        } catch {
            result = "Couldn't import: \(error.localizedDescription)"
        }
    }
}
