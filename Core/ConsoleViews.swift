import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

// The console's parts, shared by the Mac's Console window and the iPhone's Console screen.

enum Pasteboard {
    static func copy(_ text: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #else
        UIPasteboard.general.string = text
        #endif
    }
}

/// Method, params, send, reply; or (raw mode) a whole message, sent exactly as typed.
struct ConsoleComposer: View {
    let model: Model
    @AppStorage("consoleMethod") private var method = "getPilot"
    @AppStorage("consoleParams") private var params = "{}"
    @AppStorage("consoleRawMode") private var rawMode = false
    /// Off: the request has no params key at all.
    @AppStorage("consoleSendParams") private var sendParams = true
    @AppStorage("consoleRaw") private var raw = #"{"method": "getPilot", "params": {}}"#
    @AppStorage("consoleDontSwitchOn") private var keepOff = false
    @AppStorage("consoleRetry") private var retry = true
    @AppStorage("consoleFullReply") private var fullReply = false
    @State private var confirming: String?

    private var trimmedMethod: String { method.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var parsed: Result<[String: Any], JSONText.ParamsError> { JSONText.parseParams(params) }
    /// The raw message, if it's a JSON object.
    private var rawObject: [String: Any]? { Net.json(Data(raw.utf8)) }
    /// The method being sent: the one typed, or the one in the raw message (if any).
    private var currentMethod: String { rawMode ? (rawObject?["method"] as? String ?? "") : trimmedMethod }
    private var known: BulbAPI.Method? { BulbAPI.method(currentMethod) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                if rawMode {
                    Text("Raw message").font(.headline)
                } else {
                    TextField("Method", text: $method)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                        .frame(maxWidth: 260)
                }
                methodMenu
                Toggle("Raw", isOn: Binding(get: { rawMode }, set: { setRawMode($0) }))
                    .help("Edit the whole message and send it exactly as typed, without wrapping it in method and params")
                    #if os(iOS)
                    .toggleStyle(.button)
                    #endif
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

            #if os(macOS)
            // Drag the divider to give the editor or the reply more room.
            VSplitView {
                VStack(alignment: .leading, spacing: 10) { editorPane }
                    .frame(minHeight: 110)
                    .padding(.bottom, 8)
                VStack(alignment: .leading, spacing: 6) { reply }
                    .frame(minHeight: 80)
                    .padding(.top, 8)
            }
            #else
            editorPane
            Divider()
            reply
            #endif
        }
        .padding(14)
        .confirmationDialog(currentMethod.isEmpty ? "Send this message?" : "Send \(currentMethod)?",
                            isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } })) {
            Button("Send", role: .destructive) { send(confirmed: true) }
        } message: {
            Text(confirming ?? "")
        }
    }

    /// The params (or raw message) editor and its options.
    @ViewBuilder private var editorPane: some View {
        if rawMode || sendParams {
            JSONEditor(text: rawMode ? $raw : $params)
                .frame(minHeight: 70)
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.separator))
        } else {
            Text(verbatim: "No params: the request is {\"method\": \"\(trimmedMethod)\"} and nothing else.")
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 70, alignment: .topLeading)
                .padding(6)
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.separator))
        }
        HStack(spacing: 14) {
            if !rawMode {
                Toggle("Params", isOn: $sendParams)
                    .help("Send a params object (turn off to leave the key out of the request altogether)")
            }
            if rawMode || sendParams { parseStatus }
            Spacer()
            if !rawMode && trimmedMethod == "setPilot" {
                Toggle("Don't switch on", isOn: $keepOff)
                    .help(#"A setPilot without "state" switches the bulb on. While the bulb is off, this adds "state": false, as the app's own controls do, so the change waits for the bulb to be switched on"#)
            }
            Toggle("Retry", isOn: $retry)
                .disabled(rawMode && currentMethod.isEmpty)
                .help("Send again until the bulb answers (up to 6 times, as for the app's own one-off commands); needs a method to recognise the reply")
            Menu("Format") {
                Button("Indented") { format(compact: false) }
                Button("Compact") { format(compact: true) }
            } primaryAction: {
                format(compact: false)
            }
            .fixedSize()
            .disabled(rawMode ? rawObject == nil : !sendParams || (try? parsed.get()) == nil)
            .help("Tidy the JSON into indented form (or, from the menu, onto one line)")
        }
        .font(.callout)
        #if os(iOS)
        .toggleStyle(.button) // a row of switches doesn't fit on a phone
        #endif
    }

    private var canSend: Bool {
        guard model.link != .none else { return false }
        if rawMode { return !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        return !trimmedMethod.isEmpty && (!sendParams || (try? parsed.get()) != nil)
    }

    /// Carries the request across: into one message when turning raw on, and back into method
    /// and params when turning it off (if the message has them).
    private func setRawMode(_ on: Bool) {
        if on {
            if !sendParams {
                raw = JSONText.pretty(["method": trimmedMethod])
            } else if let p = try? parsed.get() {
                raw = JSONText.pretty(["method": trimmedMethod, "params": p] as [String: Any])
            } else {
                raw = "{\"method\": \"\(trimmedMethod)\", \"params\": \(params)}"
            }
        } else if let obj = rawObject, let m = obj["method"] as? String {
            method = m
            sendParams = obj["params"] != nil
            let p = obj["params"] as? [String: Any] ?? [:]
            params = p.isEmpty ? "{}" : JSONText.pretty(p)
        }
        rawMode = on
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
                    if let caution = known.caution {
                        Label(caution, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    }
                }
            } else if !currentMethod.isEmpty {
                Text("Not a method the bulb takes over UDP, as far as setPilot knows: it's sent as typed.").foregroundStyle(.secondary)
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
        }
    }

    @ViewBuilder private var parseStatus: some View {
        if rawMode {
            if let obj = rawObject {
                if obj["method"] is String {
                    Label("Valid JSON", systemImage: "checkmark.circle").foregroundStyle(.secondary)
                } else {
                    Label("No method: sent as typed", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
            } else {
                Label("Not a JSON object: sent exactly as typed", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
        } else {
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
    }

    /// The reply to show: just its `result` (or `error`), or the whole message with Full Reply on.
    /// Anything that isn't JSON is shown as it came.
    private var shownReply: (text: String, isJSON: Bool)? {
        if let failure = model.consoleFailure { return (failure, false) }
        guard let text = model.consoleReply else { return nil }
        guard let obj = Net.json(Data(text.utf8)) else { return (text, false) }
        if fullReply { return (JSONText.pretty(obj), true) }
        if let result = obj["result"] { return (JSONText.pretty(result), true) }
        if let error = obj["error"] { return (JSONText.pretty(["error": error]), true) }
        return (JSONText.pretty(obj), true)
    }

    @ViewBuilder private var reply: some View {
        HStack {
            Text("Reply").font(.headline)
            Spacer()
            Toggle("Full reply", isOn: $fullReply)
                .help("Show the whole message the bulb sent, not just its result")
                #if os(iOS)
                .toggleStyle(.button)
                #endif
            if let shown = shownReply {
                Button {
                    Pasteboard.copy(shown.text)
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                .buttonStyle(.borderless)
            }
        }
        .font(.callout)
        ScrollView {
            Group {
                if let shown = shownReply {
                    if model.consoleFailure != nil {
                        Text(shown.text).foregroundStyle(.red)
                    } else if shown.isJSON {
                        Text(JSONHighlighter.highlight(shown.text))
                    } else {
                        Text(shown.text)
                    }
                } else if let waiting = model.consoleWaiting {
                    Text(verbatim: waiting.isEmpty ? "Waiting for a reply…" : "Waiting for \(waiting)…").foregroundStyle(.secondary)
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
        let template = (try? JSONText.parseParams(m.template).get()) ?? [:]
        if rawMode {
            raw = JSONText.pretty(["method": m.name, "params": template] as [String: Any])
        } else {
            method = m.name
            params = template.isEmpty ? "{}" : JSONText.pretty(template)
        }
    }

    private func format(compact: Bool) {
        func text(_ v: Any) -> String { compact ? JSONText.compact(v) : JSONText.pretty(v) }
        if rawMode {
            if let obj = rawObject { raw = text(obj) }
        } else if let p = try? parsed.get() {
            params = p.isEmpty ? "{}" : text(p)
        }
    }

    private func send(confirmed: Bool = false) {
        guard canSend else { return }
        if !confirmed, let caution = known?.caution {
            confirming = caution
            return
        }
        if rawMode {
            model.sendRawText(raw, retry: retry)
        } else if !sendParams {
            model.sendRaw(trimmedMethod, nil, keepOff: keepOff, retry: retry)
        } else if let p = try? parsed.get() {
            model.sendRaw(trimmedMethod, p, keepOff: keepOff, retry: retry)
        }
    }
}

/// The log: newest first, filterable, each entry copyable or loadable into the console.
struct ConsoleLog: View {
    let model: Model
    @AppStorage("logShowPushes") private var showPushes = true
    @AppStorage("logShowRegistration") private var showRegistration = true
    @AppStorage("consoleMethod") private var method = "getPilot"
    @AppStorage("consoleParams") private var params = "{}"
    @AppStorage("consoleRaw") private var raw = ""
    @AppStorage("consoleRawMode") private var rawMode = false
    @AppStorage("consoleSendParams") private var sendParams = true
    @AppStorage(Model.logLimitKey) private var limit = 1000
    /// Rows indented over several lines, rather than one line each.
    @AppStorage("logPretty") private var pretty = false
    /// After "Edit in Console" has loaded a request (the iPhone switches to the console with it).
    var onEdit: () -> Void = {}

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
                Toggle("Indented", isOn: $pretty)
                    .help("Show each message indented over several lines")
                #if os(macOS)
                keepPicker
                copyAll
                clear
                #else
                Menu {
                    keepPicker
                    copyAll
                    clear
                } label: {
                    Label("More", systemImage: "ellipsis.circle")
                }
                .labelStyle(.iconOnly)
                #endif
            }
            .font(.callout)
            #if os(iOS)
            .toggleStyle(.button)
            #endif
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
                            LogRow(entry: entry, pretty: pretty) { load(entry) }
                                .contextMenu { menu(entry) }
                            Divider()
                        }
                    }
                }
            }
        }
    }

    private var keepPicker: some View {
        Picker("Keep", selection: Binding(get: { limit }, set: { new in
            limit = new
            model.trimLog()
        })) {
            ForEach(Model.logLimitChoices, id: \.self) { Text(verbatim: "\($0) entries").tag($0) }
        }
        .fixedSize()
        .help("How many entries the log keeps; the oldest go first")
    }

    private var copyAll: some View {
        Button("Copy All") { Pasteboard.copy(model.logText(shown)) }
            .disabled(shown.isEmpty)
    }

    private var clear: some View {
        Button("Clear", role: .destructive) { model.log.removeAll() }
            .disabled(model.log.isEmpty)
    }

    @ViewBuilder private func menu(_ entry: LogEntry) -> some View {
        Button("Copy") {
            Pasteboard.copy(entry.text)
        }
        if entry.kind != .failure {
            Button("Edit in Console") { load(entry) }
        }
    }

    /// Puts a message into the console: a request as method and params (or as a raw message, in
    /// raw mode or if it has no method); anything else (a reply, a push) as a raw message.
    private func load(_ entry: LogEntry) {
        raw = Net.json(Data(entry.text.utf8)).map { JSONText.pretty($0) } ?? entry.text
        if let request = entry.request {
            method = request.method
            sendParams = request.params != nil
            let p = request.params ?? [:]
            params = p.isEmpty ? "{}" : JSONText.pretty(p)
        } else {
            rawMode = true
        }
        onEdit()
    }
}

struct LogRow: View {
    let entry: LogEntry
    var pretty = false
    /// Loads the message into the console (nil: no button, e.g. for failures).
    var onLoad: (() -> Void)? = nil

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
                    Text(JSONHighlighter.highlight(pretty ? (Net.json(Data(entry.text.utf8)).map { JSONText.pretty($0) } ?? entry.text) : entry.text))
                }
            }
            .lineLimit(pretty ? nil : 4)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            if entry.kind != .failure, let onLoad {
                Button(action: onLoad) {
                    Image(systemName: "square.and.arrow.up.on.square")
                }
                .buttonStyle(.borderless)
                .help("Put this message into the console")
                .accessibilityLabel("Edit in console")
            }
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

#if os(macOS)
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
#endif

#if os(iOS)
/// A plain-text editor for JSON, coloured as you type. Smart quotes and dashes are off, so what's
/// typed stays valid JSON.
struct JSONEditor: UIViewRepresentable {
    @Binding var text: String

    static let font = UIFont.monospacedSystemFont(ofSize: UIFont.preferredFont(forTextStyle: .callout).pointSize, weight: .regular)

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.delegate = context.coordinator
        view.font = Self.font
        view.backgroundColor = .clear
        view.autocorrectionType = .no
        view.autocapitalizationType = .none
        view.spellCheckingType = .no
        view.smartQuotesType = .no
        view.smartDashesType = .no
        view.smartInsertDeleteType = .no
        view.keyboardType = .asciiCapable
        view.textContainerInset = UIEdgeInsets(top: 6, left: 2, bottom: 6, right: 2)
        view.accessibilityLabel = "Params"
        view.text = text
        Self.colour(view)
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        context.coordinator.parent = self
        guard view.text != text else { return }
        view.text = text
        Self.colour(view)
    }

    /// Recolours in place, so the text, selection and any marked (composing) text are kept.
    static func colour(_ view: UITextView) {
        let storage = view.textStorage
        let all = NSRange(location: 0, length: storage.length)
        storage.beginEditing()
        storage.addAttributes([.font: font, .foregroundColor: UIColor.label], range: all)
        for (range, kind) in JSONHighlighter.tokens(storage.string) where range.upperBound <= storage.length {
            storage.addAttribute(.foregroundColor, value: uiColour(kind),
                                 range: NSRange(location: range.lowerBound, length: range.count))
        }
        storage.endEditing()
        view.typingAttributes = [.font: font, .foregroundColor: UIColor.label]
    }

    private static func uiColour(_ kind: JSONHighlighter.Kind) -> UIColor {
        switch kind {
        case .key: .systemBlue
        case .string: .systemRed
        case .number: .systemPurple
        case .literal: .systemPink
        case .punctuation: .secondaryLabel
        }
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: JSONEditor
        init(_ parent: JSONEditor) { self.parent = parent }

        func textViewDidChange(_ view: UITextView) {
            JSONEditor.colour(view)
            parent.text = view.text
        }
    }
}
#endif
