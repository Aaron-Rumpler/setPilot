import AppIntents
import SwiftUI
import WidgetKit

// The same widgets and controls on iPhone (Home Screen, Lock Screen, StandBy, Control Center) and
// the Mac (desktop, Notification Center, Control Center and the menu bar).

/// The widget, or (in a Mac build without a development team, so no App Group to read) a note
/// saying what it needs.
struct NeedsSharing<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        if SharedStore.isShared {
            content()
        } else {
            Text("setPilot's widgets need a build with App Groups and a development team.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: Timeline

struct BulbEntry: TimelineEntry {
    let date: Date
    let snapshot: LightSnapshot?
    let presets: [Preset]

    static let sample = BulbEntry(date: .now, snapshot: {
        var s = LightSnapshot()
        s.link = .connected
        s.bulbName = "Lounge lamp"
        s.isOn = true
        s.dimming = 60
        return s
    }(), presets: [
        Preset(name: "Reading", colour: .temp(4200), dimming: 100),
        Preset(name: "Evening", colour: .temp(2700), dimming: 60),
        Preset(name: "Movie", colour: .rgbcw(r: 255, g: 60, b: 0, c: 0, w: 40), dimming: 30),
        Preset(name: "Night", colour: .rgbcw(r: 255, g: 0, b: 0, c: 0, w: 10), dimming: 10),
    ])
}

/// The app reloads the widgets when the state or presets change; nothing changes by itself.
struct BulbProvider: TimelineProvider {
    func placeholder(in context: Context) -> BulbEntry { .sample }

    func getSnapshot(in context: Context, completion: @escaping (BulbEntry) -> Void) {
        completion(context.isPreview ? .sample : current)
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<BulbEntry>) -> Void) {
        completion(Timeline(entries: [current], policy: .never))
    }

    private var current: BulbEntry {
        BulbEntry(date: .now, snapshot: SharedStore.snapshot, presets: SharedStore.presets.favourites)
    }
}

// MARK: Presets (Home Screen)

/// Which presets the Presets widget shows (Edit Widget): none chosen shows the favourites, in order.
struct PresetsWidgetConfiguration: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Presets"
    static let description = IntentDescription("Choose the presets to show, in order; none shows your favourites.")

    @Parameter(title: "Presets")
    var presets: [PresetEntity]?

    init() {}
}

struct PresetsProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> BulbEntry { .sample }

    func snapshot(for configuration: PresetsWidgetConfiguration, in context: Context) async -> BulbEntry {
        context.isPreview ? .sample : entry(configuration)
    }

    /// The app reloads the widgets when the state or presets change; nothing changes by itself.
    func timeline(for configuration: PresetsWidgetConfiguration, in context: Context) async -> Timeline<BulbEntry> {
        Timeline(entries: [entry(configuration)], policy: .never)
    }

    private func entry(_ configuration: PresetsWidgetConfiguration) -> BulbEntry {
        let all = SharedStore.presets
        // None chosen: the favourites.
        var seen = Set<UUID>() // a preset chosen twice shows once
        let chosen = (configuration.presets ?? []).compactMap { p in all.first { $0.id == p.id } }.filter { seen.insert($0.id).inserted }
        return BulbEntry(date: .now, snapshot: SharedStore.snapshot, presets: chosen.isEmpty ? all.favourites : chosen)
    }
}

struct PresetsWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "presets", intent: PresetsWidgetConfiguration.self, provider: PresetsProvider()) { entry in
            NeedsSharing { PresetsWidgetView(entry: entry) }
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Presets")
        .description("Your favourite setPilot presets (or the ones you choose), with the bulb's power and brightness.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

struct PresetsWidgetView: View {
    let entry: BulbEntry
    /// The size; set only by the snapshot tests (outside a widget the environment's isn't a real one).
    var size: WidgetFamily? = nil
    @Environment(\.widgetFamily) private var environmentFamily
    private var family: WidgetFamily { size ?? environmentFamily }
    /// Full colour, or tinted and clear (iOS 18 and 26, macOS 26), where colours are taken away.
    @Environment(\.widgetRenderingMode) private var renderingMode

    private var count: Int {
        switch family {
        case .systemSmall: 4
        case .systemMedium: 6
        default: 12
        }
    }

    private var columns: Int { family == .systemSmall ? 2 : 3 }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if entry.presets.isEmpty {
                Text(SharedStore.presets.isEmpty ? "Save presets in setPilot." : "No favourites yet. Star presets in setPilot, or choose some with Edit Widget.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            } else {
                Grid(horizontalSpacing: 6, verticalSpacing: 6) {
                    ForEach(rows, id: \.first?.id) { row in
                        GridRow {
                            ForEach(row) { preset in
                                Button(intent: ApplyPresetWidgetIntent(preset: PresetEntity(preset))) {
                                    tile(preset)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }

    private var rows: [[Preset]] {
        let shown = Array(entry.presets.prefix(count))
        return stride(from: 0, to: shown.count, by: columns).map { Array(shown[$0..<min($0 + columns, shown.count)]) }
    }

    private var header: some View {
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 0) {
                Text(entry.snapshot?.bulbName ?? "setPilot")
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                Text(statusText(entry.snapshot))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if family != .systemSmall {
                Button(intent: DimStepIntent(step: -10)) { Image(systemName: "sun.min") }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Dimmer")
                Button(intent: DimStepIntent(step: 10)) { Image(systemName: "sun.max.fill") }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Brighter")
            }
            Toggle(isOn: entry.snapshot?.isOn ?? false, intent: powerIntent) {
                Image(systemName: entry.snapshot?.isOn == true ? "lightbulb.fill" : "lightbulb")
            }
            .toggleStyle(.button)
            .labelStyle(.iconOnly)
            .accessibilityLabel("Power")
        }
    }

    private var powerIntent: PowerToggleIntent {
        let i = PowerToggleIntent()
        i.value = !(entry.snapshot?.isOn ?? false)
        return i
    }

    private func tile(_ preset: Preset) -> some View {
        VStack(spacing: 2) {
            swatch(preset)
                .overlay {
                    if preset.colour.isScene {
                        Image(systemName: "sparkles").font(.caption2.weight(.bold)).foregroundStyle(.white)
                    }
                }
            Text(preset.name)
                .font(.caption2)
                .lineLimit(1)
        }
    }
}

extension PresetsWidgetView {
    /// The preset's colour; without colour (tinted, clear), the tint, as light as the colour is,
    /// so presets can still be told apart.
    @ViewBuilder fileprivate func swatch(_ preset: Preset) -> some View {
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        let rgb = SharedStore.swatch(preset.colour)
        if renderingMode == .fullColor {
            shape.fill((rgb?.color ?? .gray).gradient)
        } else {
            let lightness = rgb.map { 0.2126 * $0.r + 0.7152 * $0.g + 0.0722 * $0.b } ?? 0.3
            shape.fill(Color.primary.opacity(0.25 + 0.6 * lightness))
                .overlay(shape.strokeBorder(Color.primary.opacity(0.5), lineWidth: 1))
                .widgetAccentable()
        }
    }
}

func statusText(_ s: LightSnapshot?) -> String {
    guard let s else { return "Open setPilot" }
    switch s.link {
    case .none: return "No bulb chosen"
    case .connecting: return "Connecting…"
    case .unreachable: return "Not answering"
    case .connected:
        switch s.isOn {
        case true?: return "On · \(Int(s.dimming))%"
        case false?: return "Off"
        case nil: return "Reading…" // answering, but its state isn't known yet (or was refused)
        }
    }
}

// MARK: Status (Lock Screen)

struct StatusWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "status", provider: BulbProvider()) { entry in
            NeedsSharing { StatusWidgetView(entry: entry) }
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Bulb")
        .description("Whether the bulb is on, and how bright, with power and brightness buttons.")
        #if os(iOS)
        .supportedFamilies([.accessoryCircular, .accessoryRectangular, .accessoryInline, .systemSmall])
        #else
        .supportedFamilies([.systemSmall])
        #endif
    }
}

struct StatusWidgetView: View {
    let entry: BulbEntry
    /// The size; set only by the snapshot tests (outside a widget the environment's isn't a real one).
    var size: WidgetFamily? = nil
    @Environment(\.widgetFamily) private var environmentFamily
    private var family: WidgetFamily { size ?? environmentFamily }

    var body: some View {
        let s = entry.snapshot
        // On only while it's answering: the status line says "Not answering" for the same state.
        let on = s?.link == .connected && s?.isOn == true
        switch family {
        case .systemSmall:
            // Home Screen, StandBy, the Mac's desktop: the bulb, its brightness, and its controls.
            VStack(alignment: .leading, spacing: 6) {
                Image(systemName: on ? "lightbulb.fill" : "lightbulb")
                    .font(.title2)
                    .foregroundStyle(on ? Color.yellow : Color.secondary)
                    .widgetAccentable()
                Text(s?.bulbName ?? "setPilot").font(.headline).lineLimit(1)
                Text(statusText(s)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 0)
                HStack {
                    Button(intent: DimStepIntent(step: -10)) { Image(systemName: "sun.min") }
                        .accessibilityLabel("Dimmer")
                    Button(intent: DimStepIntent(step: 10)) { Image(systemName: "sun.max.fill") }
                        .accessibilityLabel("Brighter")
                    Spacer(minLength: 0)
                    Toggle(isOn: on, intent: {
                        let i = PowerToggleIntent()
                        i.value = !(s?.isOn ?? false) // from the last known state, answering or not
                        return i
                    }()) {
                        Image(systemName: "power")
                    }
                    .toggleStyle(.button)
                    .labelStyle(.iconOnly)
                    .accessibilityLabel("Power")
                }
                .buttonStyle(.plain)
                .font(.title3)
            }
        #if os(iOS)
        case .accessoryCircular:
            Gauge(value: on ? (s?.dimming ?? 0) : 0, in: 0...100) {
                Image(systemName: on ? "lightbulb.fill" : "lightbulb")
            }
            .gaugeStyle(.accessoryCircularCapacity)
        case .accessoryInline:
            Label(statusText(s), systemImage: on ? "lightbulb.fill" : "lightbulb")
        #endif
        default:
            HStack {
                VStack(alignment: .leading) {
                    Text(s?.bulbName ?? "setPilot").font(.headline).lineLimit(1)
                    Text(statusText(s)).lineLimit(1)
                }
                Spacer(minLength: 0)
                Toggle(isOn: on, intent: {
                    let i = PowerToggleIntent()
                    i.value = !(s?.isOn ?? false) // from the last known state, answering or not
                    return i
                }()) {
                    Image(systemName: on ? "lightbulb.fill" : "lightbulb")
                }
                .toggleStyle(.button)
                .labelStyle(.iconOnly)
                .accessibilityLabel("Power")
            }
        }
    }
}

// MARK: Control Center

struct PowerControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "power", provider: PowerValueProvider()) { isOn in
            ControlWidgetToggle("Bulb", isOn: isOn, action: PowerToggleIntent()) { on in
                Label(on ? "On" : "Off", systemImage: on ? "lightbulb.fill" : "lightbulb")
            }
        }
        .displayName("Bulb Power")
        .description("Switches the setPilot bulb on or off.")
    }
}

struct PowerValueProvider: ControlValueProvider {
    var previewValue: Bool { true }

    func currentValue() async throws -> Bool { SharedStore.snapshot?.isOn ?? false }
}

struct PresetControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        AppIntentControlConfiguration(kind: "preset", intent: PresetControlConfiguration.self) { config in
            ControlWidgetButton(action: ApplyPresetWidgetIntent(preset: config.preset)) {
                Label(config.preset?.name ?? "Preset", systemImage: "square.grid.2x2")
            }
        }
        .displayName("Preset")
        .description("Applies one of your setPilot presets.")
        .promptsForUserConfiguration()
    }
}

struct BrighterControl: ControlWidget {
    // (Two types, not one with a flag: a control is made with init().)
    private let up = true

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: up ? "brighter" : "dimmer") {
            ControlWidgetButton(action: DimStepIntent(step: up ? 10 : -10)) {
                Label(up ? "Brighter" : "Dimmer", systemImage: up ? "sun.max.fill" : "sun.min")
            }
        }
        .displayName(up ? "Brighter" : "Dimmer")
        .description(up ? "Makes the setPilot bulb brighter by 10%." : "Makes the setPilot bulb dimmer by 10%.")
    }
}

struct DimmerControl: ControlWidget {
    // (Two types, not one with a flag: a control is made with init().)
    private let up = false

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: up ? "brighter" : "dimmer") {
            ControlWidgetButton(action: DimStepIntent(step: up ? 10 : -10)) {
                Label(up ? "Brighter" : "Dimmer", systemImage: up ? "sun.max.fill" : "sun.min")
            }
        }
        .displayName(up ? "Brighter" : "Dimmer")
        .description(up ? "Makes the setPilot bulb brighter by 10%." : "Makes the setPilot bulb dimmer by 10%.")
    }
}
