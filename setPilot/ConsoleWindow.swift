import SwiftUI

/// Window › Console: send any method with any params and see the reply, above a log of
/// everything sent to and received from the bulb.
struct ConsoleWindow: View {
    let model: Model

    var body: some View {
        VSplitView {
            ConsoleComposer(model: model)
                .frame(minHeight: 300, idealHeight: 380)
            ConsoleLog(model: model)
                .frame(minHeight: 160)
        }
        .frame(minWidth: 560, minHeight: 520)
        .navigationTitle(model.currentName.map { "Console — \($0)" } ?? "Console")
    }
}
