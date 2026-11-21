import Foundation

/// Which build this is: the version, and the commit it was built from (stamped into the Info.plist
/// by tools/stamp-commit.sh; "-dirty" if there were uncommitted changes).
enum BuildInfo {
    static let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    static let commit = Bundle.main.object(forInfoDictionaryKey: "SetPilotCommit") as? String

    /// "1.0 (3f9c2a1b)", or "1.0" without a commit.
    static var summary: String { commit.map { "\(version) (\($0))" } ?? version }
}
