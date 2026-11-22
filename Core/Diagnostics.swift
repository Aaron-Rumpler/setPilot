import Foundation
import OSLog
import SwiftUI
import UniformTypeIdentifiers
#if canImport(MetricKit)
import MetricKit
#endif

/// A report to attach to a bug: the app and system, recent messages to and from the bulb,
/// setPilot's own log, and crash and hang reports the system has given it (MetricKit). MAC
/// addresses, signing keys and signatures are taken out.
@MainActor
enum Diagnostics {
    static func report(model: Model) async -> String {
        var out: [String] = []
        let info = Bundle.main.infoDictionary ?? [:]
        out.append("setPilot \(info["CFBundleShortVersionString"] as? String ?? "?") (\(BuildInfo.commit ?? "no commit stamp"))")
        out.append("\(ProcessInfo.processInfo.operatingSystemVersionString), \(Self.machine)")
        out.append("Bulb: \(model.link), \(model.status.isEmpty ? "no status" : model.status)")
        out.append("iCloud sync: \(CloudSync.isEnabled ? CloudLibrary.shared.progress.status : "off in this build")")
        out.append("")
        out.append("== Messages (newest \(min(model.log.count, 500)))")
        out.append(contentsOf: model.log.suffix(500).map(\.line))
        out.append("")
        out.append("== setPilot's log (the last day)")
        out.append(contentsOf: await Task.detached { Self.systemLog() }.value)
        out.append("")
        out.append("== Crash and hang reports")
        let reports = MetricReports.saved()
        out.append(contentsOf: reports.isEmpty ? ["None"] : reports)
        return redact(out.joined(separator: "\n"))
    }

    /// MACs (bare or with separators) and key-like values out.
    static func redact(_ text: String) -> String {
        var t = text
        let patterns = [
            #"\b[0-9A-Fa-f]{2}([:-])(?:[0-9A-Fa-f]{2}\1){4}[0-9A-Fa-f]{2}\b"#, // aa:bb:cc:dd:ee:ff
            #"\b[0-9A-Fa-f]{12}\b"#, // aabbccddeeff, as WiZ writes them
            #""(mac|hmac|signingKey|key|udp_signing_key)"\s*:\s*"[^"]*""#,
        ]
        for (i, p) in patterns.enumerated() {
            guard let re = try? NSRegularExpression(pattern: p) else { continue }
            let range = NSRange(t.startIndex..., in: t)
            t = re.stringByReplacingMatches(in: t, range: range, withTemplate: i == 2 ? "\"$1\":\"(removed)\"" : "(MAC removed)")
        }
        return t
    }

    nonisolated private static func systemLog() -> [String] {
        guard let store = try? OSLogStore(scope: .currentProcessIdentifier) else { return ["Couldn't read it"] }
        let since = store.position(date: Date.now.addingTimeInterval(-86_400))
        let predicate = NSPredicate(format: "subsystem == %@", Log.subsystem)
        guard let entries = try? store.getEntries(at: since, matching: predicate) else { return ["Couldn't read it"] }
        let lines = entries.compactMap { $0 as? OSLogEntryLog }.map {
            "\($0.date.formatted(LogEntry.timeFormat)) [\($0.category)] \($0.composedMessage)"
        }
        return lines.isEmpty ? ["Nothing since launch"] : lines
    }

    private static var machine: String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var model = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("hw.model", &model, &size, nil, 0)
        let name = String(cString: model)
        #if os(iOS)
        // hw.model is the board on iPhone; hw.machine is the model (iPhone17,1 and so on).
        var msize = 0
        sysctlbyname("hw.machine", nil, &msize, nil, 0)
        var machine = [CChar](repeating: 0, count: max(msize, 1))
        sysctlbyname("hw.machine", &machine, &msize, nil, 0)
        return String(cString: machine)
        #else
        return name
        #endif
    }
}

/// Crash, hang and other diagnostic reports the system hands setPilot (MetricKit), kept as JSON
/// in Application Support (the newest 10) for the diagnostics report.
final class MetricReports: NSObject, @unchecked Sendable {
    static let shared = MetricReports()

    private static var folder: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Diagnostics", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func start() {
        #if canImport(MetricKit)
        MXMetricManager.shared.add(self)
        #endif
    }

    static func saved() -> [String] {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent > $1.lastPathComponent }
            .prefix(10).compactMap { try? String(contentsOf: $0, encoding: .utf8) }
    }

    fileprivate static func save(_ json: Data) {
        let name = "\(Int(Date.now.timeIntervalSince1970))-\(UUID().uuidString.prefix(8)).json"
        try? json.write(to: folder.appendingPathComponent(name))
        let files = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent > $1.lastPathComponent }
        for old in files.dropFirst(10) { try? FileManager.default.removeItem(at: old) }
    }
}

#if canImport(MetricKit)
extension MetricReports: MXMetricManagerSubscriber {
    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for p in payloads { Self.save(p.jsonRepresentation()) }
    }
}
#endif

/// Settings' Export Diagnostics: the report as a text file, to attach to a bug report.
struct DiagnosticsExportButton: View {
    let model: Model
    @State private var document: DiagnosticsDocument?
    @State private var preparing = false

    var body: some View {
        Button(preparing ? "Preparing…" : "Export Diagnostics…") {
            preparing = true
            Task {
                document = DiagnosticsDocument(text: await Diagnostics.report(model: model))
                preparing = false
            }
        }
        .disabled(preparing)
        .fileExporter(isPresented: Binding(get: { document != nil }, set: { if !$0 { document = nil } }),
                      document: document, contentType: .plainText,
                      defaultFilename: "setPilot Diagnostics \(Date.now.formatted(.iso8601.year().month().day()))") { _ in
            document = nil
        }
    }
}

struct DiagnosticsDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.plainText]
    var text: String

    init(text: String) { self.text = text }

    init(configuration: ReadConfiguration) throws {
        text = String(decoding: configuration.file.regularFileContents ?? Data(), as: UTF8.self)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}

/// Settings' diagnostics section.
struct DiagnosticsSection: View {
    let model: Model

    var body: some View {
        Section {
            DiagnosticsExportButton(model: model)
        } header: {
            Text("Diagnostics")
        } footer: {
            Text("A text file for a bug report: the app and system versions, recent messages to and from the bulb, setPilot's log, and any crash reports. MAC addresses and signing keys are left out; bulb addresses are kept.")
                #if os(macOS)
                .font(.callout)
                .foregroundStyle(.secondary)
                #endif
        }
    }
}
