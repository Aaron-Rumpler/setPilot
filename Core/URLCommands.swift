import Foundation
#if os(macOS)
import AppKit
#else
import UIKit
#endif

// Running setpilot:// links (parsed in Scripting/URLCommandParsing.swift).

extension URLCommands {
    /// Runs a setpilot:// link, then opens its callback (if it has one).
    @MainActor
    static func handle(_ url: URL, model: Model) async {
        let result: ScriptResult
        switch command(from: url) {
        case .success(let command): result = await Scripting.run(command, fade: fade(from: url), on: model)
        case .failure(let error): result = ScriptResult(state: nil, error: error)
        }
        // Without a callback, a failure shows as the status (there's nowhere else to say it).
        if let error = result.error, callback(for: url, result: result) == nil { model.status = error.message }
        guard let back = callback(for: url, result: result) else { return }
        #if os(macOS)
        NSWorkspace.shared.open(back)
        #else
        _ = await UIApplication.shared.open(back)
        #endif
    }
}
