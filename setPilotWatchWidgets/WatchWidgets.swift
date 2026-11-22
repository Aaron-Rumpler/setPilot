import AppIntents
import SwiftUI
import WidgetKit

// Complications and Smart Stack widgets. They show what the watch app last heard from the
// iPhone (kept in the App Group) and open the app when tapped; a preset widget applies its
// preset through the app (watch widgets can't reach the iPhone themselves).

@main
struct SetPilotWatchWidgets: WidgetBundle {
    var body: some Widget {
        BulbStatusWidget()
        PresetWidget()
        PowerWidget()
        WatchPowerControl()
        WatchPresetControl()
        WatchBrighterControl()
        WatchDimmerControl()
    }
}

// MARK: Controls (Control Center, the Smart Stack, the Action button)

// They open the watch app with a link (Common/WatchControls.swift), which asks the iPhone.

struct WatchPowerControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "power-control") {
            ControlWidgetButton(action: WatchLinkIntent(link: "setpilot://power/toggle")) {
                Label("Bulb", systemImage: "lightbulb")
            }
        }
        .displayName("Bulb Power")
        .description("Switches the setPilot bulb on or off.")
    }
}

struct WatchBrighterControl: ControlWidget {
    // (Two types, not one with a flag: a control is made with init().)
    private let up = true

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: up ? "brighter-control" : "dimmer-control") {
            ControlWidgetButton(action: WatchLinkIntent(link: up ? "setpilot://brighter" : "setpilot://dimmer")) {
                Label(up ? "Brighter" : "Dimmer", systemImage: up ? "sun.max.fill" : "sun.min")
            }
        }
        .displayName(up ? "Brighter" : "Dimmer")
        .description(up ? "Makes the setPilot bulb brighter by 10%." : "Makes the setPilot bulb dimmer by 10%.")
    }
}

struct WatchDimmerControl: ControlWidget {
    // (Two types, not one with a flag: a control is made with init().)
    private let up = false

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: up ? "brighter-control" : "dimmer-control") {
            ControlWidgetButton(action: WatchLinkIntent(link: up ? "setpilot://brighter" : "setpilot://dimmer")) {
                Label(up ? "Brighter" : "Dimmer", systemImage: up ? "sun.max.fill" : "sun.min")
            }
        }
        .displayName(up ? "Brighter" : "Dimmer")
        .description(up ? "Makes the setPilot bulb brighter by 10%." : "Makes the setPilot bulb dimmer by 10%.")
    }
}

struct WatchPresetControlConfiguration: ControlConfigurationIntent {
    static let title: LocalizedStringResource = "Preset"

    @Parameter(title: "Preset")
    var preset: WatchPresetEntity?

    init() {}
}

struct WatchPresetControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        AppIntentControlConfiguration(kind: "preset-control", intent: WatchPresetControlConfiguration.self) { config in
            ControlWidgetButton(action: WatchLinkIntent(link: config.preset.map { "setpilot://preset/\($0.id.uuidString)" } ?? "setpilot://open")) {
                Label(config.preset?.name ?? "Preset", systemImage: "square.grid.2x2")
            }
        }
        .displayName("Preset")
        .description("Applies one of your setPilot presets.")
        .promptsForUserConfiguration()
    }
}

struct BulbEntry: TimelineEntry {
    let date: Date
    let snapshot: LightSnapshot?
    var preset: Preset? = nil
    /// How strongly the Smart Stack should put this forward (around the times you usually apply
    /// the preset, or any preset).
    var relevance: TimelineEntryRelevance? = nil

    /// Entries every half hour for the next day, each as relevant as `keys` (presets, or power
    /// on/off; any, if nil) usually are then (Common/PresetUsage.swift).
    static func timeline(preset: Preset?, keys: Set<String>?, snapshot: LightSnapshot?) -> Timeline<BulbEntry> {
        let now = Date.now
        let uses = PresetUsage.load(SharedStore.defaults)
        let entries = (0..<48).map { i -> BulbEntry in
            let date = now.addingTimeInterval(Double(i) * 1800)
            // The middle of the half hour it stands for.
            let score = PresetUsage.usualness(uses, keys: keys, at: date.addingTimeInterval(900), now: now)
            return BulbEntry(date: date, snapshot: snapshot, preset: preset,
                             relevance: TimelineEntryRelevance(score: Float(score), duration: 1800))
        }
        // Worked out again tomorrow (or sooner, when the app reloads the widgets).
        return Timeline(entries: entries, policy: .after(now.addingTimeInterval(86_400)))
    }

    static let sample: BulbEntry = {
        var s = LightSnapshot()
        s.link = .connected
        s.bulbName = "Lounge lamp"
        s.isOn = true
        s.dimming = 60
        return BulbEntry(date: .now, snapshot: s, preset: Preset(name: "Evening", colour: .temp(2700), dimming: 60))
    }()
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

// MARK: Status

struct StatusProvider: TimelineProvider {
    /// What its relevance follows: the power switch for the power complication, anything (nil) for status.
    var keys: Set<String>? = nil

    func placeholder(in context: Context) -> BulbEntry { .sample }
    func getSnapshot(in context: Context, completion: @escaping (BulbEntry) -> Void) {
        completion(context.isPreview ? .sample : BulbEntry(date: .now, snapshot: SharedStore.snapshot))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<BulbEntry>) -> Void) {
        completion(BulbEntry.timeline(preset: nil, keys: keys, snapshot: SharedStore.snapshot))
    }
}

struct BulbStatusWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "status", provider: StatusProvider()) { entry in
            StatusView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
                .widgetURL(URL(string: "setpilot://open"))
        }
        .configurationDisplayName("Bulb")
        .description("Whether the bulb is on, and how bright.")
        .supportedFamilies([.accessoryCircular, .accessoryRectangular, .accessoryInline, .accessoryCorner])
    }
}

struct StatusView: View {
    let entry: BulbEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        let s = entry.snapshot
        let on = s?.isOn == true
        let symbol = on ? "lightbulb.fill" : "lightbulb"
        switch family {
        case .accessoryCircular:
            Gauge(value: on ? (s?.dimming ?? 0) : 0, in: 0...100) { Image(systemName: symbol) }
                .gaugeStyle(.accessoryCircularCapacity)
        case .accessoryCorner:
            Image(systemName: symbol)
                .font(.title2)
                .widgetLabel { Text(statusText(s)) }
        case .accessoryInline:
            Label(statusText(s), systemImage: symbol)
        default:
            VStack(alignment: .leading, spacing: 2) {
                Label(s?.bulbName ?? "setPilot", systemImage: symbol)
                    .font(.headline)
                    .lineLimit(1)
                Text(statusText(s)).lineLimit(1)
                if on, let s {
                    Gauge(value: s.dimming, in: 0...100) { EmptyView() }
                        .gaugeStyle(.accessoryLinearCapacity)
                }
            }
        }
    }
}

// MARK: Preset

struct WatchPresetEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Preset"
    static let defaultQuery = WatchPresetQuery()

    var id: UUID
    var name: String
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }

    init(_ preset: Preset) {
        id = preset.id
        name = preset.name
    }
}

struct WatchPresetQuery: EntityQuery {
    func entities(for identifiers: [UUID]) async throws -> [WatchPresetEntity] {
        let presets = SharedStore.presets // in the order asked
        return identifiers.compactMap { id in presets.first { $0.id == id } }.map(WatchPresetEntity.init)
    }

    func suggestedEntities() async throws -> [WatchPresetEntity] {
        SharedStore.presets.map(WatchPresetEntity.init)
    }
}

struct PresetWidgetConfiguration: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Preset"

    @Parameter(title: "Preset")
    var preset: WatchPresetEntity?

    init() {}
    init(preset: WatchPresetEntity) { self.preset = preset }
}

struct PresetProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> BulbEntry { .sample }

    func snapshot(for configuration: PresetWidgetConfiguration, in context: Context) async -> BulbEntry {
        context.isPreview ? .sample : entry(configuration)
    }

    func timeline(for configuration: PresetWidgetConfiguration, in context: Context) async -> Timeline<BulbEntry> {
        let e = entry(configuration)
        return BulbEntry.timeline(preset: e.preset, keys: e.preset.map { [$0.id.uuidString] }, snapshot: e.snapshot)
    }

    /// The watch has no widget configuration screen: one suggestion per preset.
    func recommendations() -> [AppIntentRecommendation<PresetWidgetConfiguration>] {
        SharedStore.presets.prefix(12).map {
            AppIntentRecommendation(intent: PresetWidgetConfiguration(preset: WatchPresetEntity($0)), description: Text($0.name))
        }
    }

    private func entry(_ configuration: PresetWidgetConfiguration) -> BulbEntry {
        let preset = configuration.preset.flatMap { p in SharedStore.presets.first { $0.id == p.id } }
        return BulbEntry(date: .now, snapshot: SharedStore.snapshot, preset: preset)
    }
}

struct PresetWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "preset", intent: PresetWidgetConfiguration.self, provider: PresetProvider()) { entry in
            PresetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
                .widgetURL(URL(string: entry.preset.map { "setpilot://preset/\($0.id.uuidString)" } ?? "setpilot://open"))
        }
        .configurationDisplayName("Preset")
        .description("Applies a preset when tapped.")
        .supportedFamilies([.accessoryCircular, .accessoryRectangular, .accessoryInline, .accessoryCorner])
    }
}

struct PresetView: View {
    let entry: BulbEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        let name = entry.preset?.name ?? "Preset"
        let colour = entry.preset.flatMap { SharedStore.swatch($0.colour) }?.color ?? .gray
        switch family {
        case .accessoryCircular:
            ZStack {
                AccessoryWidgetBackground()
                VStack(spacing: 0) {
                    Circle().fill(colour).frame(width: 14, height: 14)
                    Text(name).font(.system(size: 10, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.6)
                }
                .padding(4)
            }
        case .accessoryCorner:
            Image(systemName: "square.grid.2x2.fill")
                .foregroundStyle(colour)
                .widgetLabel { Text(name) }
        case .accessoryInline:
            Label(name, systemImage: "square.grid.2x2")
        default:
            HStack(spacing: 8) {
                Circle().fill(colour.gradient).frame(width: 26, height: 26)
                VStack(alignment: .leading, spacing: 1) {
                    Text(name).font(.headline).lineLimit(1)
                    Text(entry.preset.map { "\($0.dimming)% · tap to apply" } ?? "Choose a preset")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
    }
}

// MARK: Power

struct PowerWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "power", provider: StatusProvider(keys: [PresetUsage.powerOn, PresetUsage.powerOff])) { entry in
            let isOn = entry.snapshot?.isOn
            let on = isOn == true
            ZStack {
                AccessoryWidgetBackground()
                // Unknown: neutral, as the status complication shows it.
                Image(systemName: on ? "lightbulb.fill" : isOn == false ? "lightbulb.slash" : "lightbulb").font(.title3)
            }
            .containerBackground(.fill.tertiary, for: .widget)
            .widgetURL(URL(string: "setpilot://power/toggle"))
            .accessibilityLabel(isOn == nil ? "Switch the bulb on or off" : on ? "Switch the bulb off" : "Switch the bulb on")
        }
        .configurationDisplayName("Power")
        .description("Switches the bulb on or off when tapped.")
        .supportedFamilies([.accessoryCircular])
    }
}
