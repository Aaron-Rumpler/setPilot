import SwiftUI
import WidgetKit

// On its own so the unit tests can build the widgets' views (they render them) without it.

@main
struct SetPilotWidgets: WidgetBundle {
    var body: some Widget {
        PresetsWidget()
        StatusWidget()
        PowerControl()
        PresetControl()
        BrighterControl()
        DimmerControl()
        #if os(iOS)
        LightShowLiveActivityWidget()
        #endif
    }
}
