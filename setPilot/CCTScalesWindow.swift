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
        // Not while the stored scales are a newer build's: nothing here would reach them, or iCloud.
        let locked = !model.library.canEdit(Library.cctScalesKey)
        NavigationSplitView {
            List(selection: $selection) {
                // Stored by a newer build this one can't read (some taken from iCloud meanwhile are
                // listed): why they can't be added to or changed. Empty, the overlay says it.
                if !scales.isEmpty, let note = model.library.newerNote(forScalesOf: model.chosenMAC) {
                    Text(note).font(.callout).foregroundStyle(.secondary)
                }
                ForEach(scales) { scale in
                    CCTScaleRow(scale: scale, inUse: model.scaleForTemperature == scale.id)
                        .tag(scale.id)
                        .contextMenu {
                            Button("Use for Temperature") { model.assignTemperatureScale(scale.id) }
                                .disabled(scale.range == nil)
                            Button("Duplicate") { selection = model.duplicateScale(scale)?.id }
                                .disabled(locked)
                            Divider()
                            Button("Delete…", role: .destructive) { deleting = scale }
                                .disabled(locked)
                        }
                }
            }
            .overlay {
                if scales.isEmpty {
                    ContentUnavailableView {
                        Label("No Scales", systemImage: "thermometer.medium")
                    } description: {
                        Text(model.library.newerNote(forScalesOf: model.chosenMAC) ?? (model.chosenMAC == nil
                             ? "Connect to a bulb first: scales are kept per bulb."
                             : "A scale turns kelvin into RGBCW, for Temperature's Scale choice. Start from the bulb's own table and change it, or extend it below 2200 K."))
                    } actions: {
                        Button("New Scale") { selection = model.newScale()?.id }
                            .disabled(model.chosenMAC == nil || !model.library.canEdit(Library.cctScalesKey))
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 220, ideal: 240)
            .toolbar {
                ToolbarItem {
                    Button { selection = model.newScale()?.id } label: { Label("New Scale", systemImage: "plus") }
                        .disabled(model.chosenMAC == nil || !model.library.canEdit(Library.cctScalesKey))
                        .help(model.defaultScale == nil ? "New scale" : "New scale from the bulb's own table")
                }
            }
        } detail: {
            if let selection, scales.contains(where: { $0.id == selection }) {
                CCTScaleEditor(model: model, scaleID: selection).id(selection)
                    .handoff(.cctScale(selection))
            } else {
                Text(scales.isEmpty ? "" : "Select a scale").foregroundStyle(.secondary)
                    .handoff(.cctScales)
            }
        }
        // Handoff from another device (setPilot/App.swift opens this window).
        .onChange(of: HandoffRouter.shared.scaleToSelect, initial: true) { _, id in
            guard let id else { return }
            HandoffRouter.shared.scaleToSelect = nil
            // Only this bulb's scales are listed: another bulb's (or one not synced yet) isn't here.
            if model.library.scales(for: model.chosenMAC).contains(where: { $0.id == id }) { selection = id }
        }
        .navigationTitle(model.currentName.map { "CCT Scales — \($0)" } ?? "CCT Scales")
        .onDeleteCommand { if !locked { deleting = scales.first { $0.id == selection } } }
        .onChange(of: deleting?.name) { _, name in if let name { deletingName = name } }
        .confirmationDialog("Delete “\(deleting?.name ?? deletingName)”?",
                            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            presenting: deleting) { d in
            Button("Delete", role: .destructive) {
                if let mac = model.chosenMAC, model.library.canEdit(Library.cctScalesKey) {
                    model.library.removeScale(d.id, for: mac)
                    if selection == d.id { selection = nil }
                }
                deleting = nil
            }
        } message: { _ in
            Text("Presets that use it will stop working.")
        }
        .onAppear { if selection == nil { selection = model.activeScale?.id ?? scales.first?.id } }
    }
}
