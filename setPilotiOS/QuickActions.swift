import SwiftUI
import UIKit

/// Home Screen quick actions (touch and hold the app's icon): power, and the first three presets.
@MainActor
enum QuickActions {
    private static let power = "nz.aaronrumpler.setPilot.power"
    private static let preset = "nz.aaronrumpler.setPilot.preset"

    /// Sets the actions from the presets (at launch and when they change).
    static func update(_ library: Library) {
        var items = [UIApplicationShortcutItem(type: power, localizedTitle: "Power", localizedSubtitle: "On or off",
                                               icon: UIApplicationShortcutIcon(systemImageName: "power"))]
        for p in library.presets.prefix(3) {
            items.append(UIApplicationShortcutItem(type: preset, localizedTitle: p.name, localizedSubtitle: "Preset",
                                                   icon: UIApplicationShortcutIcon(systemImageName: "square.grid.2x2"),
                                                   userInfo: ["id": p.id.uuidString as NSString]))
        }
        UIApplication.shared.shortcutItems = items
    }

    /// Runs one, once the bulb can be controlled (the app may have just launched for it).
    static func perform(_ item: UIApplicationShortcutItem) {
        let model = Shared.model
        Task {
            guard await model.waitUntilControllable(timeout: 5) else { return }
            switch item.type {
            case power:
                model.power(model.isOn != true)
            case preset:
                guard let id = (item.userInfo?["id"] as? String).flatMap(UUID.init(uuidString:)),
                      let p = model.library.presets.first(where: { $0.id == id }) else { return }
                _ = model.apply(p)
            default:
                break
            }
        }
    }
}

/// Quick actions arrive at the scene: when the app is running, and when one launched it.
final class PhoneSceneDelegate: NSObject, UIWindowSceneDelegate {
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        if let item = connectionOptions.shortcutItem {
            MainActor.assumeIsolated { QuickActions.perform(item) }
        }
    }

    func windowScene(_ windowScene: UIWindowScene, performActionFor shortcutItem: UIApplicationShortcutItem,
                     completionHandler: @escaping (Bool) -> Void) {
        MainActor.assumeIsolated { QuickActions.perform(shortcutItem) }
        completionHandler(true)
    }
}
