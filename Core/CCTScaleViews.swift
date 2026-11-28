import SwiftUI

extension Model {
    /// A new scale for the chosen bulb: a copy of the bulb's own table if it's known (otherwise a
    /// plain warm-to-cool scale). Not made the one in use (see below).
    @discardableResult
    func newScale() -> CCTScale? {
        // Not while the stored scales are a newer build's (Library.newerNote): it would be lost.
        guard let mac = chosenMAC, library.canEdit(Library.cctScalesKey) else { return nil }
        var scale = defaultScale ?? CCTScale(name: "Scale", points: [
            .init(kelvin: 2700, w: 255), .init(kelvin: 6500, c: 255),
        ])
        scale.name = uniqueScaleName(defaultScale == nil ? "Scale" : "Bulb default", for: mac)
        library.updateScale(scale, for: mac)
        // Not made active: it would look chosen (in the editor and the Scale picker) while the
        // light stayed on the scale in use. "Use for Temperature" makes it the one; a bulb's first
        // scale is active anyway (the active one falls back to the first).
        return scale
    }

    func duplicateScale(_ scale: CCTScale) -> CCTScale? {
        guard let mac = chosenMAC, library.canEdit(Library.cctScalesKey) else { return nil }
        var copy = scale
        copy.id = UUID()
        copy.name = uniqueScaleName(scale.name + " copy", for: mac)
        copy.points = scale.points.map { var p = $0; p.id = UUID(); return p }
        // Before it's added (and saved): a newer build's fields go with it.
        library.copyExtras(from: scale.id, to: copy.id,
                           remapping: Dictionary(zip(scale.points.map(\.id), copy.points.map(\.id)), uniquingKeysWith: { a, _ in a }))
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

    /// Temperature's scale, as a picker selection: nil for the bulb's own.
    var temperatureScaleChoice: Binding<UUID?> {
        Binding(get: { self.temperatureScale }, set: { self.useTemperatureScale($0) })
    }

    /// The scales Temperature can use: this bulb's, with a range.
    var usableScales: [CCTScale] { library.scales(for: chosenMAC).filter { $0.range != nil } }
}

/// Temperature's Scale picker: the bulb's own, or one of your CCT scales.
struct TemperatureScalePicker: View {
    let model: Model

    var body: some View {
        Picker("CCT Scale", selection: model.temperatureScaleChoice) {
            // Sections, not a Divider (SceneMenuItems).
            Section { Text("Bulb's own").tag(UUID?.none) }
            let scales = model.usableScales
            if !scales.isEmpty {
                Section { ForEach(scales) { Text($0.name).tag(Optional($0.id)) } }
            }
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
            // Not edited while the stored scales are a newer build's: changes would be lost.
            let locked = !model.library.canEdit(Library.cctScalesKey)
            Form {
                // Also for a bulb whose own stored scales are a newer build's (kept aside meanwhile).
                if let note = model.library.newerNote(forScalesOf: mac) {
                    Section { Label(note, systemImage: "info.circle").foregroundStyle(.secondary) }
                }
                Section {
                    NameField(name: binding.name, untitled: "Untitled Scale")
                        .disabled(locked)
                    ScaleStrip(scale: scale)
                        .frame(height: 14)
                        .clipShape(Capsule())
                    if model.scaleForTemperature == scaleID {
                        Label("In use by Temperature", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.secondary)
                    } else {
                        Button("Use for Temperature") { model.assignTemperatureScale(scaleID) }
                            .disabled(scale.range == nil) // needs two points to cover any kelvin
                    }
                    Button {
                        if let extended = scale.extendedDownwards() { binding.wrappedValue = extended }
                    } label: {
                        Text(verbatim: "Extend Below \(scale.sorted.first?.kelvin ?? 0) K") // verbatim: no "1,541"
                    }
                    .disabled(scale.points.count >= 32 || scale.extendedDownwards() == nil || locked)
                } footer: {
                    Text("Between points, each channel changes in a straight line with kelvin, as in the bulb's own table, so a scale made from the bulb's default gives exactly what its temperature setting gives. Extending continues the line between the two lowest points until red is full, as WiZ's table would (on the ESP25_SHRGB_01's default, at about 1540 K). Changes apply the next time the kelvin is set.")
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
                        .disabled(locked)
                    }
                }
                Section {
                    Button {
                        let last = scale.sorted.last
                        var p = last ?? CCTScale.Point(kelvin: 2700)
                        p.id = UUID()
                        p.kelvin = min((last?.kelvin ?? 2600) + 100, 20000) // as a point's kelvin field allows
                        binding.wrappedValue.points.append(p)
                    } label: {
                        Label("Add Point", systemImage: "plus")
                    }
                    .disabled(scale.points.count >= 32 || (scale.sorted.last?.kelvin ?? 0) >= 20000 || locked)
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
            // Not once it's gone (a field committing as the editor closes after a delete would put
            // it back: updateScale adds a scale it doesn't find).
            set: { new in
                guard lib.canEdit(Library.cctScalesKey) else { return } // (the views are disabled too)
                if lib.scales(for: mac).contains(where: { $0.id == scaleID }) { lib.updateScale(new, for: mac) }
            }
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
                guard scale.wrappedValue.points.count < 32 else { return } // may have changed meanwhile
                var copy = point
                copy.id = UUID()
                scale.wrappedValue.points.append(copy)
            }
            .disabled(scale.wrappedValue.points.count >= 32)
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
    @FocusState private var kelvinFocused: Bool
    /// At least this wide, so it lines up with the other rows; wider with larger text (iPhone and iPad).
    @ScaledMetric private var labelWidth: CGFloat = 100

    var body: some View {
        HStack {
            Text("Temperature").frame(minWidth: labelWidth, alignment: .leading)
            TextField("Temperature", value: Binding(get: { point.kelvin }, set: { point.kelvin = min(max($0, 500), 20000) }),
                      format: .number.grouping(.never))
                .focused($kelvinFocused)
                .labelsHidden()
                .multilineTextAlignment(.trailing)
                #if os(iOS)
                .keyboardType(.numberPad)
                // The number pad has no Return: Done ends editing, which is when the kelvin is taken
                // (not as it's typed, which would re-sort the point at every digit).
                .toolbar {
                    if kelvinFocused {
                        ToolbarItemGroup(placement: .keyboard) {
                            Spacer()
                            Button("Done") { kelvinFocused = false }
                        }
                    }
                }
                #endif
            Text("K").foregroundStyle(.secondary)
            RoundedRectangle(cornerRadius: 5)
                .fill((LightColour.rgbcw(r: point.r, g: point.g, b: point.b, c: point.c, w: point.w).swatch?.color ?? .black))
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.separator))
                .frame(width: 36, height: 22)
                // What the point's channels look like, in words.
                .accessibilityElement()
                .accessibilityLabel("Point colour")
                .accessibilityValue(LightColour.rgbcw(r: point.r, g: point.g, b: point.b, c: point.c, w: point.w).colourName ?? "")
        }
        IntSliderRow(label: "Red", value: $point.r, range: 0...255, tint: .red)
        IntSliderRow(label: "Green", value: $point.g, range: 0...255, tint: .green)
        IntSliderRow(label: "Blue", value: $point.b, range: 0...255, tint: .blue)
        IntSliderRow(label: "Cool white", value: $point.c, range: 0...255, tint: ColourTemperature.color(kelvin: 6500))
        IntSliderRow(label: "Warm white", value: $point.w, range: 0...255, tint: ColourTemperature.color(kelvin: 2700))
    }
}
