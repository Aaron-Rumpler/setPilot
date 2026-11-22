import SwiftUI

/// Every read the bulb answers over UDP, each a collapsible section with its reply as the bulb
/// sent it (or the error, flagged in the header). The light and identity start open.
struct DeviceInfoView: View {
    let model: Model
    @State private var expanded = BulbAPI.deviceInfoExpanded

    private var methods: [String] { BulbAPI.deviceInfo }
    private var allExpanded: Bool { methods.allSatisfy(expanded.contains) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                summary
                Spacer()
                Button(allExpanded ? "Collapse All" : "Expand All") {
                    expanded = allExpanded ? [] : Set(methods)
                }
                Button {
                    Pasteboard.copy(allText)
                } label: {
                    Label("Copy All", systemImage: "doc.on.doc")
                }
                .disabled(model.info.isEmpty)
                .help("Copy every reply, each under its method's name")
            }
            .buttonStyle(.borderless)
            .font(.callout)

            ForEach(methods, id: \.self) { method in
                section(method)
            }
        }
    }

    @ViewBuilder private var summary: some View {
        let read = methods.filter { model.info[$0] != nil && !model.infoReading.contains($0) }.count
        let failed = methods.filter { model.infoErrors[$0] != nil }.count
        HStack(spacing: 6) {
            if read < methods.count {
                ProgressView().controlSize(.small)
                Text(verbatim: "Reading… \(read) of \(methods.count)")
            } else if failed > 0 {
                Text(verbatim: "\(failed) of \(methods.count) had no reply or an error")
            } else {
                Text(verbatim: "All \(methods.count) read")
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
    }

    private func section(_ method: String) -> some View {
        let isOpen = expanded.contains(method)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Button {
                    if isOpen { expanded.remove(method) } else { expanded.insert(method) }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.secondary)
                            .rotationEffect(.degrees(isOpen ? 90 : 0))
                            .frame(width: 12)
                        Text(verbatim: method)
                            .font(.headline.monospaced())
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(method)
                .accessibilityValue(isOpen ? "Expanded" : "Collapsed")
                .help(BulbAPI.method(method)?.summary ?? "")

                // Being read again: that, rather than the last read's error.
                if model.info[method] == nil || model.infoReading.contains(method) {
                    ProgressView().controlSize(.mini)
                } else if let error = model.infoErrors[method] {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .lineLimit(1)
                }
                Spacer()
                if let text = model.info[method] {
                    Button {
                        Pasteboard.copy(text)
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .buttonStyle(.borderless)
                    .help("Copy this reply")
                    .accessibilityLabel("Copy \(method)")
                }
            }
            if isOpen, let text = model.info[method] {
                Text(JSONHighlighter.highlight(text))
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 18)
            }
        }
    }

    /// Every reply read so far, in order, each under its method's name.
    private var allText: String {
        methods.compactMap { m in model.info[m].map { "\(m)\n\($0)" } }.joined(separator: "\n\n")
    }
}
