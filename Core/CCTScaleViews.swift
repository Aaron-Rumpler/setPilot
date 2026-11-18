import SwiftUI

extension Model {
    /// A new scale for the chosen bulb: a copy of the bulb's own table if it's known (otherwise a
    /// plain warm-to-cool scale), made the one in use.
    @discardableResult
    func newScale() -> CCTScale? {
        guard let mac = chosenMAC else { return nil }
        var scale = defaultScale ?? CCTScale(name: "Scale", points: [
            .init(kelvin: 2700, w: 255), .init(kelvin: 6500, c: 255),
        ])
        scale.name = uniqueScaleName(defaultScale == nil ? "Scale" : "Bulb default", for: mac)
        library.updateScale(scale, for: mac)
        library.setActiveScale(scale.id, for: mac)
        return scale
    }

    func duplicateScale(_ scale: CCTScale) -> CCTScale? {
        guard let mac = chosenMAC else { return nil }
        var copy = scale
        copy.id = UUID()
        copy.name = uniqueScaleName(scale.name + " copy", for: mac)
        copy.points = scale.points.map { var p = $0; p.id = UUID(); return p }
        library.updateScale(copy, for: mac)
        return copy
    }

    /// `base`, or "base 2" and so on if this bulb already has a scale of that name.
    private func uniqueScaleName(_ base: String, for mac: String) -> String {
        let taken = Set(library.scales(for: mac).map(\.name))
        guard taken.contains(base) else { return base }
        var i = 2
        while taken.contains("\(base) \(i)") { i += 1 }
        return "\(base) \(i)"
    }

    /// The scale in use, as a picker selection.
    var scaleChoice: Binding<UUID?> {
        Binding(get: { self.activeScale?.id }, set: { if let id = $0 { self.useScale(id) } })
    }
}

/// Explains Custom CCT when the bulb has no scale yet, with a button to make one.
struct NoScaleView: View {
    let model: Model
    var openEditor: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(model.chosenMAC == nil
                 ? "Connect to the bulb to set up a custom CCT scale for it."
                 : "Custom CCT turns a kelvin value into RGBCW through a scale of your own, starting from the bulb's table. It can go beyond the bulb's 2200–6500 K.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Create a Scale…") {
                model.newScale()
                openEditor()
            }
            .disabled(model.chosenMAC == nil)
        }
    }
}

/// The scales of the chosen bulb, for a list.
struct CCTScaleRow: View {
    let scale: CCTScale
    var inUse = false

    var body: some View {
        HStack(spacing: 10) {
            ScaleStrip(scale: scale)
                .frame(width: 44, height: 18)
                .clipShape(RoundedRectangle(cornerRadius: 4))
            VStack(alignment: .leading, spacing: 1) {
                Text(scale.name)
                Text(rangeText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if inUse {
                Spacer()
                Image(systemName: "checkmark").foregroundStyle(.tint).accessibilityLabel("In use")
            }
        }
    }

    private var rangeText: String {
        guard let r = scale.range else { return "\(scale.points.count) points" }
        return "\(r.lowerBound)–\(r.upperBound) K · \(scale.points.count) points"
    }
}

/// The scale's colours across its range, from its own RGBCW values (an approximation, as for
/// preset swatches).
struct ScaleStrip: View {
    let scale: CCTScale

    var body: some View {
        if let range = scale.range {
            LinearGradient(stops: (0...16).compactMap { i in
                let t = Double(i) / 16
                let k = range.lowerBound + Int(Double(range.upperBound - range.lowerBound) * t)
                guard let ch = scale.channels(at: k),
                      let rgb = LightColour.rgbcw(r: ch.r, g: ch.g, b: ch.b, c: ch.c, w: ch.w).swatch else { return nil }
                return .init(color: rgb.color, location: t)
            }, startPoint: .leading, endPoint: .trailing)
            .accessibilityHidden(true)
        } else {
            Color.gray
        }
    }
}

/// Edits one of the chosen bulb's scales: name, points (kelvin and RGBCW), and the downward
/// extension.
struct CCTScaleEditor: View {
    let model: Model
    let scaleID: UUID

    var body: some View {
        if let mac = model.chosenMAC, let binding = binding(mac) {
            let scale = binding.wrappedValue
            Form {
                Section {
                    TextField("Name", text: binding.name)
                    ScaleStrip(scale: scale)
                        .frame(height: 14)
                        .clipShape(Capsule())
                    if model.activeScale?.id == scaleID {
                        Label("Used by Custom CCT", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.secondary)
                    } else {
                        Button("Use for Custom CCT") { model.useScale(scaleID) }
                    }
                    Button("Extend Below \(scale.sorted.first?.kelvin ?? 0) K") {
                        if let extended = scale.extendedDownwards() { binding.wrappedValue = extended }
                    }
                    .disabled(scale.extendedDownwards() == nil)
                } footer: {
                    Text("Between points, each channel changes in a straight line with kelvin, as in the bulb's own table, so a scale made from the bulb's default gives exactly what its temperature setting gives. Extending continues the line between the two lowest points until red is full, as WiZ's table would (about 1540 K on this bulb's default). Changes apply the next time the kelvin is set.")
                }
                ForEach(scale.sorted) { point in
                    if let p = pointBinding(binding, point.id) {
                        Section {
                            PointEditor(point: p)
                        } header: {
                            HStack {
                                Text(verbatim: "\(point.kelvin) K")
                                Spacer()
                                pointMenu(binding, point)
                            }
                        }
                    }
                }
                Section {
                    Button {
                        let last = scale.sorted.last
                        var p = last ?? CCTScale.Point(kelvin: 2700)
                        p.id = UUID()
                        p.kelvin = (last?.kelvin ?? 2600) + 100
                        binding.wrappedValue.points.append(p)
                    } label: {
                        Label("Add Point", systemImage: "plus")
                    }
                    .disabled(scale.points.count >= 32)
                }
            }
            .formStyle(.grouped)
            .navigationTitle(scale.name)
        } else {
            Text("No scale selected").foregroundStyle(.secondary)
        }
    }

    private func binding(_ mac: String) -> Binding<CCTScale>? {
        let lib = model.library
        guard let scale = lib.scales(for: mac).first(where: { $0.id == scaleID }) else { return nil }
        return Binding(
            get: { lib.scales(for: mac).first { $0.id == scaleID } ?? scale },
            set: { lib.updateScale($0, for: mac) }
        )
    }

    private func pointBinding(_ scale: Binding<CCTScale>, _ id: UUID) -> Binding<CCTScale.Point>? {
        guard let point = scale.wrappedValue.points.first(where: { $0.id == id }) else { return nil }
        return Binding(
            get: { scale.wrappedValue.points.first { $0.id == id } ?? point },
            set: { new in
                if let i = scale.wrappedValue.points.firstIndex(where: { $0.id == id }) { scale.wrappedValue.points[i] = new }
            }
        )
    }

    private func pointMenu(_ scale: Binding<CCTScale>, _ point: CCTScale.Point) -> some View {
        Menu {
            Button("Duplicate") {
                var copy = point
                copy.id = UUID()
                scale.wrappedValue.points.append(copy)
            }
            Button("Delete", role: .destructive) { scale.wrappedValue.points.removeAll { $0.id == point.id } }
                .disabled(scale.wrappedValue.points.count <= 2)
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.button)
        .buttonStyle(.borderless)
        .fixedSize()
        .accessibilityLabel("\(point.kelvin) K actions")
    }
}

/// One point: its kelvin and RGBCW values.
struct PointEditor: View {
    @Binding var point: CCTScale.Point

    var body: some View {
        HStack {
            Text("Kelvin").frame(width: 100, alignment: .leading)
            TextField("Kelvin", value: Binding(get: { point.kelvin }, set: { point.kelvin = min(max($0, 500), 20000) }),
                      format: .number.grouping(.never))
                .labelsHidden()
                .multilineTextAlignment(.trailing)
                #if os(iOS)
                .keyboardType(.numberPad)
                #endif
            Text("K").foregroundStyle(.secondary)
            RoundedRectangle(cornerRadius: 5)
                .fill((LightColour.rgbcw(r: point.r, g: point.g, b: point.b, c: point.c, w: point.w).swatch?.color ?? .black))
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.separator))
                .frame(width: 36, height: 22)
                .accessibilityHidden(true)
        }
        IntSliderRow(label: "Red", value: $point.r, range: 0...255, tint: .red)
        IntSliderRow(label: "Green", value: $point.g, range: 0...255, tint: .green)
        IntSliderRow(label: "Blue", value: $point.b, range: 0...255, tint: .blue)
        IntSliderRow(label: "Cool white", value: $point.c, range: 0...255, tint: ColourTemperature.color(kelvin: 6500))
        IntSliderRow(label: "Warm white", value: $point.w, range: 0...255, tint: ColourTemperature.color(kelvin: 2700))
    }
}
