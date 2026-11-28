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
    var pending: LibraryFile? {
        didSet {
            if pending != nil { showWindow() } else if oldValue != nil, !waiting.isEmpty { // closed: the next
                let next = waiting.removeFirst()
                DispatchQueue.main.async { // once this question's gone
                    MainActor.assumeIsolated {
                        // Another opened in the moment between: this one's still first.
                        if self.pending == nil { self.pending = next } else { self.waiting.insert(next, at: 0) }
                    }
                }
            }
        }
    }
    private var waiting: [LibraryFile] = []
    /// Why something opened here couldn't be added.
    var problem: String? { didSet { if problem != nil { showWindow() } } }

    /// The question is asked in the main window: opened for it on the Mac, where the app may be
    /// in the menu bar only.
    private func showWindow() {
        #if os(macOS)
        HandoffRouter.shared.open(.controls)
        #endif
    }

    /// From a setpilot://import link.
    func take(link url: URL) {
        guard let b64 = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "item" })?.value
        else { problem = "That link has nothing to add in it."; return }
        var s = b64.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while s.count % 4 != 0 { s += "=" }
        guard let data = Data(base64Encoded: s) else { problem = "That link is incomplete: it may have been cut short."; return }
        take(data: data)
    }

    /// From a file opened in setPilot (AirDrop, Files).
    func take(file url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            take(data: try Data(contentsOf: url))
        } catch {
            problem = "Couldn't open “\(url.lastPathComponent)”: \(error.localizedDescription)"
        }
    }

    private func take(data: Data) {
        guard let file = try? JSONDecoder().decode(LibraryFile.self, from: data) else {
            problem = "That isn't a setPilot preset, scene or library."
            return
        }
        // A later format may mean something else by the same keys: don't guess.
        guard file.setPilotLibrary <= 1 else {
            problem = "That's from a newer version of setPilot. Update setPilot here to add it."
            return
        }
        guard !file.presets.isEmpty || !file.customScenes.isEmpty || file.cctScales.values.contains(where: { !$0.isEmpty }) else {
            problem = "There's nothing in that to add."
            return
        }
        offer(file)
    }

    /// Asks about a file to add: now, or after the one still being asked about.
    func offer(_ file: LibraryFile) {
        if pending != nil { waiting.append(file) } else { pending = file }
    }

    static func summary(of f: LibraryFile) -> String {
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
    /// The text kept while the alert closes (problem is cleared first).
    @State private var shownProblem = ""
    /// The question as it was, kept while the alert closes (pending is cleared first, and once
    /// added, every item would count as already here).
    @State private var shown = Question(clashes: 0, summary: "")

    private struct Question {
        var clashes: Int
        var summary: String
    }

    private var asked: Question? {
        IncomingItems.shared.pending.map { Question(clashes: model.library.clashes($0), summary: IncomingItems.summary(of: $0)) }
    }

    func body(content: Content) -> some View {
        let incoming = IncomingItems.shared
        let question = asked ?? shown
        let clashes = question.clashes
        content.alert(clashes > 0 ? "You already have some of these" : "Add to setPilot?",
                      isPresented: Binding(get: { incoming.pending != nil }, set: { if !$0 { close() } })) {
            if clashes > 0 {
                Button("Replace Mine") { add(.replace) }
                Button("Keep Both") { add(.keepBoth) }
                Button("Add Only the New Ones") { add(.skip) }
            } else {
                Button("Add") { add(.replace) }
            }
            Button("Cancel", role: .cancel) { close() }
        } message: {
            if clashes > 0 {
                Text("\(question.summary): \(clashes == 1 ? "one is" : "\(clashes) are") already here. Replace yours with these, keep both (the new ones as copies), or add only the ones you don't have?")
            } else {
                Text("\(question.summary).")
            }
        }
        .onChange(of: incoming.problem) { _, text in if let text { shownProblem = text } }
        .alert("Couldn't add it", isPresented: Binding(get: { incoming.problem != nil }, set: { if !$0 { incoming.problem = nil } })) {
            Button("OK") { incoming.problem = nil }
        } message: {
            Text(incoming.problem ?? shownProblem)
        }
    }

    private func add(_ clash: Library.Clash) {
        if let question = asked { shown = question }
        // What was added, as an import without clashes says it.
        if let file = IncomingItems.shared.pending { model.status = model.library.merge(file, clash: clash) }
        IncomingItems.shared.pending = nil
    }

    private func close() {
        if let question = asked { shown = question }
        IncomingItems.shared.pending = nil
    }
}
