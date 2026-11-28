import SwiftUI
import UIKit
#if WIZ_ICLOUD
import CloudKit
#endif

/// Home Screen quick actions (touch and hold the app's icon): power, and your three most used presets.
@MainActor
enum QuickActions {
    private static let power = "nz.aaronrumpler.setPilot.power"
    private static let preset = "nz.aaronrumpler.setPilot.preset"

    /// Sets the actions from the presets (at launch and when they change).
    static func update(_ library: Library) {
        var items = [UIApplicationShortcutItem(type: power, localizedTitle: "Power", localizedSubtitle: "On or off",
                                               icon: UIApplicationShortcutIcon(systemImageName: "power"))]
        // Favourites first, then the ones used most (recent uses counting more), then the first
        // presets, to make up three.
        let ranked = PresetUsage.mostUsed(PresetUsage.load(.standard)).compactMap { id in library.presets.first { $0.id == id } }
        var chosen = Array(library.presets.filter(\.isFavourite).prefix(3))
        for p in ranked where chosen.count < 3 && !chosen.contains(where: { $0.id == p.id }) { chosen.append(p) }
        for p in library.presets where chosen.count < 3 && !chosen.contains(where: { $0.id == p.id }) { chosen.append(p) }
        for p in chosen {
            items.append(UIApplicationShortcutItem(type: preset, localizedTitle: p.name, localizedSubtitle: "Preset",
                                                   icon: UIApplicationShortcutIcon(systemImageName: "square.grid.2x2"),
                                                   userInfo: ["id": p.id.uuidString as NSString]))
        }
        UIApplication.shared.shortcutItems = items
    }

    /// Runs one through the shared runner, as Shortcuts and widgets are (queued with them, and
    /// failing with the same reasons, shown in the status). A preset that flashes is asked about
    /// first, as everywhere a person starts one.
    static func perform(_ item: UIApplicationShortcutItem) {
        let model = Shared.model
        switch item.type {
        case power:
            run(.power(nil), model)
        case preset:
            guard let id = (item.userInfo?["id"] as? String).flatMap(UUID.init(uuidString:)) else { return }
            guard model.library.presets.contains(where: { $0.id == id }) else {
                model.status = BulbReasons.presetGone
                return
            }
            // Its time counts from the tap, not from the end of the wait below.
            let tapped = Date.now
            // The wait can take seconds: something to show it's on its way.
            let name = model.library.presets.first(where: { $0.id == id })?.name ?? ""
            let waiting = "Applying “\(name)”…"
            model.status = waiting
            Task {
                // Whether to ask is judged once the light's been read (the app may have been in the
                // background while the speed was changed elsewhere): otherwise one that flashes at
                // the real speed would go unasked, and be refused.
                // (Outside the runner's queue: a Shortcut or widget started during the wait goes
                // first, and this lands after it. Rare, so accepted.)
                if let error = await Scripting.readyToJudge(model) {
                    model.status = error.message
                    return
                }
                guard let p = model.library.presets.first(where: { $0.id == id }) else {
                    model.status = BulbReasons.presetGone
                    return
                }
                if model.asksFirst(p) {
                    if model.status == waiting { model.status = "" } // asked about instead
                    model.applyAsking(p)
                } else {
                    run(.preset(id.uuidString), model, asked: tapped)
                }
            }
        default:
            return
        }
    }

    /// A person's tap, with nothing to ask (or not asking): as if started in setPilot, so a preset
    /// of a scene stored on the bulb plays with "Ask before playing" off, as from the app's menus.
    /// `asked`: when it was tapped (its time counts from then).
    private static func run(_ command: ScriptCommand, _ model: Model, asked: Date = .now) {
        let started = !Flashing.asks
        Task {
            if let error = await Scripting.run(command, asked: asked, confirmed: started, on: model).error { model.status = error.message }
        }
    }
}

/// Quick actions arrive at the scene: when the app is running, and when one launched it.
final class PhoneSceneDelegate: NSObject, UIWindowSceneDelegate {
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        if let item = connectionOptions.shortcutItem {
            MainActor.assumeIsolated { QuickActions.perform(item) }
        }
        #if WIZ_ICLOUD
        if let metadata = connectionOptions.cloudKitShareMetadata {
            MainActor.assumeIsolated { CloudLibrary.shared.offer(metadata) }
        }
        #endif
    }

    #if WIZ_ICLOUD
    /// An invitation to a household library, opened from Messages or Mail.
    func windowScene(_ windowScene: UIWindowScene, userDidAcceptCloudKitShareWith cloudKitShareMetadata: CKShare.Metadata) {
        MainActor.assumeIsolated { CloudLibrary.shared.offer(cloudKitShareMetadata) }
    }
    #endif

    func windowScene(_ windowScene: UIWindowScene, performActionFor shortcutItem: UIApplicationShortcutItem,
                     completionHandler: @escaping (Bool) -> Void) {
        MainActor.assumeIsolated { QuickActions.perform(shortcutItem) }
        completionHandler(true)
    }
}
