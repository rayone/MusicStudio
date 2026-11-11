import Foundation

/// Single source of truth for the app's version and build, read from the bundle's
/// Info.plist (which `build.command` fills from its `VERSION` variable). Nothing in the
/// UI should hardcode a version string; use `AppInfo.version` / `AppInfo.build` so the
/// displayed value can never drift from the actual build.
public enum AppInfo {
    /// Marketing version, e.g. "0.1.0" (CFBundleShortVersionString).
    public static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "unknown"
    }

    /// Build number (CFBundleVersion). Equal to `version` in this project's build.
    public static var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
            ?? version
    }

    /// Source revision (custom `SCMRevision` key): git short SHA, with a `-dirty` suffix
    /// when the build was made from an uncommitted tree, or "nogit"/"unknown".
    public static var revision: String {
        Bundle.main.object(forInfoDictionaryKey: "SCMRevision") as? String ?? "unknown"
    }

    /// "0.1.0 (42)" style string: marketing version and build number. When build equals
    /// version (e.g. an overridden build), shows just the version.
    public static var versionWithBuild: String {
        build == version ? version : "\(version) (\(build))"
    }

    /// Headline identity for the UI: "0.1.0 · a1b2c3d". The git revision is the only
    /// portable identity — every `git pull` of a commit reproduces it, unlike the local
    /// build counter which resets per machine. Use this where the user needs to know
    /// *which build* they are running (e.g. after pulling main to test).
    public static var versionWithRevision: String {
        revision == "unknown" ? version : "\(version) · \(revision)"
    }

    /// Full provenance: "0.1.0 · a1b2c3d (build 42)" — adds the local build number after
    /// the portable revision. For bug reports and logs.
    public static var versionWithRevisionAndBuild: String {
        build == version ? versionWithRevision : "\(versionWithRevision) (build \(build))"
    }
}
