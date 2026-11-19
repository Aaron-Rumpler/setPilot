import AppKit
import SwiftUI

/// Window › Console: send any method with any params and see the reply, above a log of
/// everything sent to and received from the bulb.
struct ConsoleWindow: View {
    let model: Model

    var body: some View {
        VSplitView {
            ConsoleComposer(model: model)
                .frame(minHeight: 300, idealHeight: 380)
            ConsoleLog(model: model)
                .frame(minHeight: 160)
        }
        .frame(minWidth: 560, minHeight: 520)
        .navigationTitle(model.currentName.map { "Console — \($0)" } ?? "Console")
    }
}

/// Method, params, send, reply.
struct ConsoleComposer: View {
    let model: Model
    @AppStorage("consoleMethod") private var method = "getPilot"
    @AppStorage("consoleParams") private var params = "{}"
    @AppStorage("consoleKeepOff") private var keepOff = true
    @AppStorage("consoleRetry") private var retry = true
    @State private var confirming: String?

    private var trimmedMethod: String { method.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var known: BulbAPI.Method? { BulbAPI.method(trimmedMethod) }
    private var parsed: Result<[String: Any], JSONText.ParamsError> { JSONText.parseParams(params) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                TextField("Method", text: $method)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .autocorrectionDisabled()
                    .frame(maxWidth: 260)
                methodMenu
                Spacer()
                if model.consoleWaiting != nil { ProgressView().controlSize(.small) }
                Button {
                    send()
                } label: {
                    Label("Send", systemImage: "paperplane.fill")
                }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!canSend)
                .help("Send to the bulb (⌘↩)")
            }

            methodInfo

            JSONEditor(text: $params)
                .frame(minHeight: 70)
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.separator))
            HStack(spacing: 14) {
                parseStatus
                Spacer()
                if trimmedMethod == "setPilot" {
                    Toggle("Keep it off", isOn: $keepOff)
                        .help(#"While the bulb is off, add "state": false (a setPilot without it switches the bulb on)"#)
                }
                Toggle("Retry", isOn: $retry)
                    .help("Send again until the bulb answers (up to 6 times, as for the app's own one-off commands)")
                Button("Format") { format() }
                    .disabled((try? parsed.get()) == nil)
                    .help("Tidy the params into indented JSON")
            }
            .font(.callout)

            Divider()
            reply
        }
        .padding(14)
        .confirmationDialog("Send \(trimmedMethod)?", isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } })) {
            Button("Send", role: .destructive) { send(confirmed: true) }
        } message: {
            Text(confirming ?? "")
        }
    }

    private var canSend: Bool {
        !trimmedMethod.isEmpty && (try? parsed.get()) != nil && model.link != .none
    }

    private var methodMenu: some View {
        Menu {
            ForEach(BulbAPI.Kind.allCases, id: \.self) { kind in
                Section(kind.rawValue) {
                    ForEach(BulbAPI.all.filter { $0.kind == kind }) { m in
                        Button(m.name) { choose(m) }
                    }
                }
            }
        } label: {
            Label("Methods", systemImage: "list.bullet")
        }
        .fixedSize()
        .help("Known methods, with params to start from")
    }

    @ViewBuilder private var methodInfo: some View {
        Group {
            if let known {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(known.kind.badge)
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(badgeColour(known.kind).opacity(0.18), in: Capsule())
                            .foregroundStyle(badgeColour(known.kind))
                        Text(known.summary).foregroundStyle(.secondary)
                    }
                    if known.kind == .cloudOnly {
                        Text("The bulb refuses this over local UDP.")
                            .foregroundStyle(.secondary)
                    }
                    if let caution = known.caution {
                        Label(caution, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    }
                }
            } else if !trimmedMethod.isEmpty {
                Text("Not a method setPilot knows: it's sent as typed.").foregroundStyle(.secondary)
            }
        }
        .font(.callout)
        .fixedSize(horizontal: false, vertical: true)
        .textSelection(.enabled)
    }

    private func badgeColour(_ kind: BulbAPI.Kind) -> Color {
        switch kind {
        case .read: .blue
        case .action: .teal
        case .write: .orange
        case .cloudOnly: .gray
        }
    }

    @ViewBuilder private var parseStatus: some View {
        switch parsed {
        case .success:
            Label("Valid JSON", systemImage: "checkmark.circle").foregroundStyle(.secondary)
        case .failure(let error):
            Label(error.message, systemImage: "xmark.octagon.fill")
                .foregroundStyle(.red)
                .lineLimit(2)
                .help(error.message)
        }
    }

    @ViewBuilder private var reply: some View {
        HStack {
            Text("Reply").font(.headline)
            Spacer()
            if let text = model.consoleReply {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                .buttonStyle(.borderless)
            }
        }
        ScrollView {
            Group {
                if let text = model.consoleReply {
                    Text(JSONHighlighter.highlight(text))
                } else if let waiting = model.consoleWaiting {
                    Text(verbatim: "Waiting for \(waiting)…").foregroundStyle(.secondary)
                } else {
                    Text("Nothing sent from here yet").foregroundStyle(.tertiary)
                }
            }
            .font(.system(.callout, design: .monospaced))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minHeight: 60)
    }

    private func choose(_ m: BulbAPI.Method) {
        method = m.name
        if let p = try? JSONText.parseParams(m.template).get(), !p.isEmpty {
            params = JSONText.pretty(p)
        } else {
            params = m.template
        }
    }

    private func format() {
        guard let p = try? parsed.get() else { return }
        params = p.isEmpty ? "{}" : JSONText.pretty(p)
    }

    private func send(confirmed: Bool = false) {
        guard canSend, let p = try? parsed.get() else { return }
        if !confirmed, let caution = known?.caution {
            confirming = caution
            return
        }
        model.sendRaw(trimmedMethod, p, keepOff: keepOff, retry: retry)
    }
}

/// The log: newest first, filterable, each entry copyable or loadable into the console.
struct ConsoleLog: View {
    let model: Model
    @AppStorage("logShowPushes") private var showPushes = true
    @AppStorage("logShowRegistration") private var showRegistration = true
    @AppStorage("consoleMethod") private var method = "getPilot"
    @AppStorage("consoleParams") private var params = "{}"

    private var shown: [LogEntry] {
        model.log.filter { e in
            (showPushes || e.kind != .push) && (showRegistration || e.method != "registration")
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text("Log").font(.headline)
                Text(verbatim: "\(shown.count)").foregroundStyle(.secondary).monospacedDigit()
                Spacer()
                Toggle("Live updates", isOn: $showPushes)
                    .help("Show syncPilot pushes")
                Toggle("Registration", isOn: $showRegistration)
                    .help("Show the registration sent every 20 s for live updates, and its replies")
                Button("Copy All") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(model.logText(shown), forType: .string)
                }
                .disabled(shown.isEmpty)
                Button("Clear") { model.log.removeAll() }
                    .disabled(model.log.isEmpty)
            }
            .font(.callout)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            Divider()
            if shown.isEmpty {
                Text("Nothing yet. Requests, replies and live updates appear here as they happen.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(shown.reversed())) { entry in
                            LogRow(entry: entry)
                                .contextMenu { menu(entry) }
                            Divider()
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder private func menu(_ entry: LogEntry) -> some View {
        Button("Copy") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(entry.text, forType: .string)
        }
        if let request = entry.request {
            Button("Edit in Console") {
                method = request.method
                params = request.params.isEmpty ? "{}" : JSONText.pretty(request.params)
            }
        }
    }
}

struct LogRow: View {
    let entry: LogEntry

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(entry.date.formatted(LogEntry.timeFormat))
                .foregroundStyle(.secondary)
            Image(systemName: symbol)
                .foregroundStyle(colour)
                .frame(width: 14)
                .accessibilityLabel(label)
            Group {
                if entry.kind == .failure {
                    Text(entry.text).foregroundStyle(.red)
                } else {
                    Text(JSONHighlighter.highlight(entry.text))
                }
            }
            .lineLimit(4)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(.caption, design: .monospaced))
        .padding(.horizontal, 14)
        .padding(.vertical, 4)
    }

    private var symbol: String {
        switch entry.kind {
        case .sent: "arrow.up.right"
        case .received: "arrow.down.left"
        case .push: "dot.radiowaves.left.and.right"
        case .failure: "xmark"
        }
    }

    private var colour: Color {
        switch entry.kind {
        case .sent: .blue
        case .received: .green
        case .push: .teal
        case .failure: .red
        }
    }

    private var label: String {
        switch entry.kind {
        case .sent: "Sent"
        case .received: "Received"
        case .push: "Live update"
        case .failure: "Failed"
        }
    }
}

/// A plain-text editor for JSON, coloured as you type (NSTextView: SwiftUI's TextEditor can't be
/// coloured before macOS 26). Smart quotes and dashes are off, so what's typed stays valid JSON.
struct JSONEditor: NSViewRepresentable {
    @Binding var text: String

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        let view = scroll.documentView as! NSTextView
        view.delegate = context.coordinator
        view.isRichText = false
        view.allowsUndo = true
        view.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.isAutomaticSpellingCorrectionEnabled = false
        view.isContinuousSpellCheckingEnabled = false
        view.isGrammarCheckingEnabled = false
        view.smartInsertDeleteEnabled = false
        view.textContainerInset = NSSize(width: 4, height: 6)
        view.setAccessibilityLabel("Params")
        view.string = text
        Self.colour(view)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let view = scroll.documentView as? NSTextView, view.string != text else { return }
        view.string = text
        Self.colour(view)
    }

    /// Colours the text with temporary attributes (display only; the text stays plain).
    static func colour(_ view: NSTextView) {
        guard let layout = view.layoutManager else { return }
        let all = NSRange(location: 0, length: (view.string as NSString).length)
        layout.removeTemporaryAttribute(.foregroundColor, forCharacterRange: all)
        for (range, kind) in JSONHighlighter.tokens(view.string) {
            layout.addTemporaryAttribute(.foregroundColor, value: nsColour(kind),
                                         forCharacterRange: NSRange(location: range.lowerBound, length: range.count))
        }
    }

    private static func nsColour(_ kind: JSONHighlighter.Kind) -> NSColor {
        switch kind {
        case .key: .systemBlue
        case .string: .systemRed
        case .number: .systemPurple
        case .literal: .systemPink
        case .punctuation: .secondaryLabelColor
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: JSONEditor
        init(_ parent: JSONEditor) { self.parent = parent }

        func textDidChange(_ note: Notification) {
            guard let view = note.object as? NSTextView else { return }
            JSONEditor.colour(view)
            parent.text = view.string
        }
    }
}
