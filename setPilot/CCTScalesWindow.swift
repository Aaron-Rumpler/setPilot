import SwiftUI

/// The CCT Scales window: the chosen bulb's scales on the left, the selected one's points on the right.
struct CCTScalesWindow: View {
    let model: Model
    @State private var selection: UUID?
    @State private var deleting: CCTScale?
    /// The name in the delete confirmation, kept while it closes (deleting is cleared first).
    @State private var deletingName = ""

    var body: some View {
        let scales = model.library.scales(for: model.chosenMAC)
        NavigationSplitView {
            List(selection: $selection) {
                ForEach(scales) { scale in
                    CCTScaleRow(scale: scale, inUse: model.scaleForTemperature == scale.id)
                        .tag(scale.id)
                        .contextMenu {
                            Button("Use for Temperature") { model.assignTemperatureScale(scale.id) }
                                .disabled(scale.range == nil)
                            Button("Duplicate") { selection = model.duplicateScale(scale)?.id }
                            Divider()
                            Button("Delete…", role: .destructive) { deleting = scale }
                        }
                }
            }
            .overlay {
                if scales.isEmpty {
                    ContentUnavailableView {
                        Label("No Scales", systemImage: "thermometer.medium")
                    } description: {
                        Text(model.chosenMAC == nil
                             ? "Connect to a bulb first: scales are kept per bulb."
                             : "A scale turns kelvin into RGBCW, for Temperature's Scale choice. Start from the bulb's own table and change it, or extend it below 2200 K.")
                    } actions: {
                        Button("New Scale") { selection = model.newScale()?.id }
                            .disabled(model.chosenMAC == nil)
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 220, ideal: 240)
            .toolbar {
                ToolbarItem {
                    Button { selection = model.newScale()?.id } label: { Label("New Scale", systemImage: "plus") }
                        .disabled(model.chosenMAC == nil)
                        .help(model.defaultScale == nil ? "New scale" : "New scale from the bulb's own table")
                }
            }
        } detail: {
            if let selection, scales.contains(where: { $0.id == selection }) {
                CCTScaleEditor(model: model, scaleID: selection).id(selection)
            } else {
                Text(scales.isEmpty ? "" : "Select a scale").foregroundStyle(.secondary)
            }
        }
        .navigationTitle(model.currentName.map { "CCT Scales — \($0)" } ?? "CCT Scales")
        .onDeleteCommand { deleting = scales.first { $0.id == selection } }
        .onChange(of: deleting?.name) { _, name in if let name { deletingName = name } }
        .confirmationDialog("Delete “\(deleting?.name ?? deletingName)”?",
                            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("Delete", role: .destructive) {
                if let d = deleting, let mac = model.chosenMAC {
                    model.library.removeScale(d.id, for: mac)
                    if selection == d.id { selection = nil }
                }
                deleting = nil
            }
        } message: {
            Text("Presets that use it will stop working.")
        }
        .onAppear { if selection == nil { selection = model.activeScale?.id ?? scales.first?.id } }
    }
}
