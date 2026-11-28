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

    /// A file being asked about, with a token of its own, so a question closing clears only the
    /// file it asked about (not the next one, or one another window has just shown).
    struct Offer: Identifiable {
        let id = UUID()
        let file: LibraryFile
        /// From Import… in Settings, rather than shared with this device.
        var imported = false
    }

    var pending: Offer? {
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
    private var waiting: [Offer] = []
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
        // A later format may mean something else by the same keys: don't guess. Read first, since
        // a newer file may not decode here at all; one that's setPilot's but doesn't decode is
        // likely newer too (a colour this version lacks, say).
        let format = LibraryFile.format(of: data)
        let newer = "That's from a newer version of setPilot. Update setPilot here to add it."
        if let format, format > 1 {
            problem = newer
            return
        }
        guard let file = try? JSONDecoder().decode(LibraryFile.self, from: data) else {
            problem = format != nil ? newer : "That isn't a setPilot preset, scene or library."
            return
        }
        guard !file.presets.isEmpty || !file.customScenes.isEmpty || file.cctScales.values.contains(where: { !$0.isEmpty }) else {
            problem = "There's nothing in that to add."
            return
        }
        offer(file)
    }

    /// Asks about a file to add: now, or after the one still being asked about.
    func offer(_ file: LibraryFile, imported: Bool = false) {
        let offer = Offer(file: file, imported: imported)
        if pending != nil { waiting.append(offer) } else { pending = offer }
    }

    /// Done asking about `offer`: cleared only if it's still the one being asked about.
    func finish(_ offer: Offer) {
        if pending?.id == offer.id { pending = nil }
    }

    /// The items by name, or for more than a few (a whole library), how many of each.
    static func summary(of f: LibraryFile) -> String {
        let names = f.presets.map(\.name) + f.customScenes.map(\.name) + f.cctScales.values.flatMap { $0.map(\.name) }
        guard names.count > 4 else { return names.map { "“\($0)”" }.joined(separator: ", ") }
        return LibraryFile.counted(presets: f.presets.count, scenes: f.customScenes.count,
                                   scales: f.cctScales.values.reduce(0) { $0 + $1.count })
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
    /// The question as it was asked, kept while the alert closes (once added, every item would
    /// count as already here).
    @State private var shown: Kept?

    private struct Question {
        var clashes: Int
        var summary: String
    }

    private struct Kept {
        var id: UUID
        var question: Question
    }

    private func question(for offer: IncomingItems.Offer) -> Question {
        if let shown, shown.id == offer.id { return shown.question }
        return Question(clashes: model.library.clashes(offer.file), summary: IncomingItems.summary(of: offer.file))
    }

    func body(content: Content) -> some View {
        let incoming = IncomingItems.shared
        // presenting: the file is handed to the buttons, so it doesn't matter whether dismissing
        // clears the binding before or after their actions run; the setter clears only this file.
        let presented = incoming.pending
        let clashes = (presented.map { question(for: $0) } ?? shown?.question)?.clashes ?? 0
        content.alert(clashes > 0 ? "You already have some of these" : "Add to setPilot?",
                      isPresented: Binding(get: { incoming.pending != nil },
                                           set: { if !$0, let presented { close(presented) } }),
                      presenting: presented) { offer in
            if question(for: offer).clashes > 0 {
                Button("Replace Mine") { add(offer, .replace) }
                Button("Keep Both") { add(offer, .keepBoth) }
                Button("Add Only the New Ones") { add(offer, .skip) }
            } else {
                Button("Add") { add(offer, .replace) }
            }
            Button("Cancel", role: .cancel) { close(offer) }
        } message: { offer in
            let q = question(for: offer)
            if q.clashes > 0 {
                Text("\(q.summary): \(q.clashes == 1 ? "one is" : "\(q.clashes) are") already here. Replace yours with these, keep both (the new ones as copies), or add only the ones you don't have?")
            } else {
                Text("\(q.summary).")
            }
        }
        .onChange(of: incoming.problem) { _, text in if let text { shownProblem = text } }
        .alert("Couldn't add it", isPresented: Binding(get: { incoming.problem != nil }, set: { if !$0 { incoming.problem = nil } })) {
            Button("OK") { incoming.problem = nil }
        } message: {
            Text(incoming.problem ?? shownProblem)
        }
    }

    private func add(_ offer: IncomingItems.Offer, _ clash: Library.Clash) {
        keep(offer)
        // What was added, as an import without clashes says it.
        model.status = model.library.merge(offer.file, clash: clash, verb: offer.imported ? "Imported" : "Added")
        IncomingItems.shared.finish(offer)
    }

    private func close(_ offer: IncomingItems.Offer) {
        keep(offer)
        IncomingItems.shared.finish(offer)
    }

    private func keep(_ offer: IncomingItems.Offer) {
        if shown?.id != offer.id { shown = Kept(id: offer.id, question: question(for: offer)) }
    }
}
