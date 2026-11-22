import CoreTransferable
import SwiftUI
import UniformTypeIdentifiers

/// A preset or custom scene to give to another device or person: as a small library file (AirDrop,
/// Messages, Files; it opens in setPilot) or as a setpilot://import link (Universal Clipboard,
/// a message). A preset brings the custom scene or CCT scale it uses with it.
struct SharedItem: Transferable {
    let file: LibraryFile
    let name: String

    static let contentType = UTType(exportedAs: "nz.aaronrumpler.setpilot.item", conformingTo: .json)

    @MainActor
    static func preset(_ p: Preset, from library: Library) -> SharedItem {
        var scenes: [CustomScene] = []
        var scales: [String: [CCTScale]] = [:]
        switch p.colour {
        case .custom(let id, _): if let s = library.customScene(id) { scenes = [s] }
        case .customCCT(let id, _): if let (mac, s) = library.scale(id) { scales[mac] = [s] }
        default: break
        }
        var shared = p
        shared.favourite = nil // someone else's favourites are theirs
        return SharedItem(file: LibraryFile(presets: [shared], customScenes: scenes, cctScales: scales), name: p.name)
    }

    static func scene(_ s: CustomScene) -> SharedItem {
        SharedItem(file: LibraryFile(presets: [], customScenes: [s], cctScales: [:]), name: s.name)
    }

    /// The item as a link: setpilot://import?item=<base64url of the file>.
    var link: URL? {
        guard let data = try? JSONEncoder().encode(file) else { return nil }
        let b64 = data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        return URL(string: "setpilot://import?item=\(b64)")
    }

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: contentType) { item in
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            return try encoder.encode(item.file)
        }
        .suggestedFileName { "\($0.name).setpilot" }
        ProxyRepresentation { item in item.link ?? URL(string: "setpilot://")! }
    }
}

/// Items shared with this device (a link or a file opened in setPilot), waiting to be confirmed:
/// they're only added once you say so, since a web page can open links too.
@MainActor @Observable
final class IncomingItems {
    static let shared = IncomingItems()
    var pending: LibraryFile?

    /// From a setpilot://import link.
    func take(link url: URL) {
        guard let b64 = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "item" })?.value
        else { return }
        var s = b64.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while s.count % 4 != 0 { s += "=" }
        guard let data = Data(base64Encoded: s) else { return }
        take(data: data)
    }

    /// From a file opened in setPilot (AirDrop, Files).
    func take(file url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        if let data = try? Data(contentsOf: url) { take(data: data) }
    }

    private func take(data: Data) {
        guard let file = try? JSONDecoder().decode(LibraryFile.self, from: data), file.setPilotLibrary <= 1 else { return }
        pending = file
    }

    var summary: String {
        guard let f = pending else { return "" }
        let names = f.presets.map(\.name) + f.customScenes.map(\.name) + f.cctScales.values.flatMap { $0.map(\.name) }
        return names.map { "“\($0)”" }.joined(separator: ", ")
    }
}

extension View {
    /// Asks before adding items shared with this device.
    func incomingItemsPrompt(_ model: Model) -> some View { modifier(IncomingItemsPrompt(model: model)) }
}

private struct IncomingItemsPrompt: ViewModifier {
    let model: Model

    func body(content: Content) -> some View {
        let incoming = IncomingItems.shared
        let clashes = incoming.pending.map(model.library.clashes) ?? 0
        content.alert(clashes > 0 ? "You already have some of these" : "Add to setPilot?",
                      isPresented: Binding(get: { incoming.pending != nil }, set: { if !$0 { incoming.pending = nil } })) {
            if clashes > 0 {
                Button("Replace Mine") { add(.replace) }
                Button("Keep Both") { add(.keepBoth) }
                Button("Add Only the New Ones") { add(.skip) }
            } else {
                Button("Add") { add(.replace) }
            }
            Button("Cancel", role: .cancel) { incoming.pending = nil }
        } message: {
            if clashes > 0 {
                Text("\(incoming.summary): \(clashes == 1 ? "one is" : "\(clashes) are") already here. Replace yours with these, keep both (the new ones as copies), or add only the ones you don't have?")
            } else {
                Text("\(incoming.summary).")
            }
        }
    }

    private func add(_ clash: Library.Clash) {
        if let file = IncomingItems.shared.pending { _ = model.library.merge(file, clash: clash) }
        IncomingItems.shared.pending = nil
    }
}
