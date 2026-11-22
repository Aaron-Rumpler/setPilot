import SwiftUI

/// setPilot's folder in iCloud Drive (shown as "setPilot" in Files and the Finder), where the
/// open and save dialogs for library files and light shows start: put a show and its media there
/// on one device and it's there on the other. Builds with iCloud only.
@MainActor @Observable
final class CloudDocuments {
    static let shared = CloudDocuments()
    /// The folder's Documents directory, once iCloud has given it (nil without iCloud Drive).
    private(set) var folder: URL?

    /// Looks the folder up (iCloud can take a moment, so not on the main thread), creating it.
    func start() {
        #if WIZ_ICLOUD
        Task.detached(priority: .utility) {
            guard let base = FileManager.default.url(forUbiquityContainerIdentifier: CloudLibrary.containerID) else { return }
            let docs = base.appendingPathComponent("Documents", isDirectory: true)
            try? FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
            await MainActor.run { CloudDocuments.shared.folder = docs }
        }
        #endif
    }
}

extension View {
    /// Open and save dialogs here start in setPilot's iCloud Drive folder, when there is one.
    func startsInCloudFolder() -> some View {
        fileDialogDefaultDirectory(CloudDocuments.shared.folder)
    }
}

/// The last light show and media opened from setPilot's iCloud Drive folder, kept as paths within
/// it and synced (CloudSync), so every device can open them again; and what Handoff carries for
/// the light show (them, and where it's up to).
@MainActor
enum LastShow {
    static let mediaKey = "lightShowLastMedia"
    static let showKey = "lightShowLastShow"

    /// Its path within the iCloud Drive folder, if it's there.
    static func relative(_ url: URL) -> String? {
        guard let folder = CloudDocuments.shared.folder?.standardizedFileURL.path else { return nil }
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(folder + "/") else { return nil }
        return String(path.dropFirst(folder.count + 1))
    }

    static func resolve(_ relative: String?) -> URL? {
        guard let relative, !relative.isEmpty, let folder = CloudDocuments.shared.folder else { return nil }
        let url = folder.appendingPathComponent(relative)
        // In iCloud but not downloaded here yet: ask for it (it opens once it's down).
        if !FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.startDownloadingUbiquitousItem(at: url)
        }
        return url
    }

    static func remember(media url: URL) {
        UserDefaults.standard.set(relative(url) ?? "", forKey: mediaKey)
    }

    static func remember(show url: URL) {
        UserDefaults.standard.set(relative(url) ?? "", forKey: showKey)
    }

    static var media: URL? { resolve(UserDefaults.standard.string(forKey: mediaKey)) }
    static var show: URL? { resolve(UserDefaults.standard.string(forKey: showKey)) }

    /// For Handoff: the open show's files (if in the iCloud Drive folder) and where it's up to.
    static func handoffInfo(_ player: LightShowPlayer?) -> [String: Any] {
        var info: [String: Any] = [:]
        if let s = UserDefaults.standard.string(forKey: mediaKey), !s.isEmpty { info["media"] = s }
        if let s = UserDefaults.standard.string(forKey: showKey), !s.isEmpty { info["show"] = s }
        if let player { info["position"] = player.time }
        return info
    }
}
