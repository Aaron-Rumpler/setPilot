import SwiftUI

/// Bulb & Settings › Console: send any method and see the reply, or the log of everything sent
/// and received.
struct ConsoleView: View {
    let model: Model
    @State private var page = Page.send

    enum Page { case send, log }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Show", selection: $page) {
                Text("Send").tag(Page.send)
                Text("Log").tag(Page.log)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal)
            .padding(.top, 8)
            switch page {
            case .send: ConsoleComposer(model: model)
            case .log: ConsoleLog(model: model) { page = .send }
            }
        }
        .navigationTitle("Console")
        .navigationBarTitleDisplayMode(.inline)
    }
}
