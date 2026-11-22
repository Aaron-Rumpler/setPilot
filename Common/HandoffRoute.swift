import Foundation

/// A place in setPilot that Handoff carries between the Mac, iPhone and watch: the main controls,
/// the custom scenes or one being edited, the CCT scales or one being edited, the light show.
/// Each has an activity type of its own (listed under NSUserActivityTypes in the Info.plists).
/// Handoff is only in builds with iCloud (WIZ_ICLOUD): picking up a scene on another device
/// needs the library synced there.
enum HandoffRoute: Hashable, Sendable {
    case controls
    case customScenes
    case customScene(UUID)
    case cctScales
    case cctScale(UUID)
    case lightShow

    static let prefix = "nz.aaronrumpler.setPilot."
    static let types = ["controls", "customScenes", "customScene", "cctScales", "cctScale", "lightShow"].map { prefix + $0 }

    var activityType: String {
        switch self {
        case .controls: Self.prefix + "controls"
        case .customScenes: Self.prefix + "customScenes"
        case .customScene: Self.prefix + "customScene"
        case .cctScales: Self.prefix + "cctScales"
        case .cctScale: Self.prefix + "cctScale"
        case .lightShow: Self.prefix + "lightShow"
        }
    }

    var title: String {
        switch self {
        case .controls: "Light"
        case .customScenes, .customScene: "Custom Scenes"
        case .cctScales, .cctScale: "CCT Scales"
        case .lightShow: "Light Show"
        }
    }

    /// Fills in an activity for this place.
    func fill(_ activity: NSUserActivity) {
        activity.title = title
        activity.isEligibleForHandoff = true
        switch self {
        case .customScene(let id), .cctScale(let id): activity.userInfo = ["id": id.uuidString]
        default: activity.userInfo = [:]
        }
    }

    /// The place an activity from another device stands for.
    init?(_ activity: NSUserActivity) {
        let id = (activity.userInfo?["id"] as? String).flatMap(UUID.init(uuidString:))
        switch activity.activityType {
        case Self.prefix + "controls": self = .controls
        case Self.prefix + "customScenes": self = .customScenes
        case Self.prefix + "customScene": if let id { self = .customScene(id) } else { self = .customScenes }
        case Self.prefix + "cctScales": self = .cctScales
        case Self.prefix + "cctScale": if let id { self = .cctScale(id) } else { self = .cctScales }
        case Self.prefix + "lightShow": self = .lightShow
        default: return nil
        }
    }
}
