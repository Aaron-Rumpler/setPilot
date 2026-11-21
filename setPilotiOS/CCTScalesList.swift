import SwiftUI

/// The chosen bulb's custom CCT scales, each opening its editor.
struct CCTScalesList: View {
    let model: Model
    @State private var created: UUID?
    @State private var deleting: CCTScale?
    /// The name in the delete confirmation, kept while it closes (deleting is cleared first).
    @State private var deletingName = ""

    var body: some View {
        let scales = model.library.scales(for: model.chosenMAC)
        List {
            ForEach(scales) { scale in
                NavigationLink(value: scale.id) {
                    CCTScaleRow(scale: scale, inUse: model.scaleForTemperature == scale.id)
                }
                .contextMenu {
                    Button { model.assignTemperatureScale(scale.id) } label: { Label("Use for Temperature", systemImage: "checkmark") }
                        .disabled(scale.range == nil)
                    Button { _ = model.duplicateScale(scale) } label: { Label("Duplicate", systemImage: "plus.square.on.square") }
                    Button(role: .destructive) { deleting = scale } label: { Label("Delete", systemImage: "trash") }
                }
            }
            .onDelete { offsets in
                if let i = offsets.first { deleting = scales[i] }
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
                    Button("New Scale") { created = model.newScale()?.id }
                        .disabled(model.chosenMAC == nil)
                }
            }
        }
        .navigationTitle("CCT Scales")
        .navigationDestination(for: UUID.self) { id in CCTScaleEditor(model: model, scaleID: id) }
        .navigationDestination(item: $created) { id in CCTScaleEditor(model: model, scaleID: id) }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { created = model.newScale()?.id } label: { Label("New Scale", systemImage: "plus") }
                    .disabled(model.chosenMAC == nil)
            }
        }
        .onChange(of: deleting?.name) { _, name in if let name { deletingName = name } }
        .confirmationDialog("Delete “\(deleting?.name ?? deletingName)”?",
                            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if let d = deleting, let mac = model.chosenMAC { model.library.removeScale(d.id, for: mac) }
                deleting = nil
            }
        } message: {
            Text("Presets that use it will stop working.")
        }
    }
}
