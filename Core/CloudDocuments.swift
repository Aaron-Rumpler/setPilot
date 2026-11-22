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
