import Foundation

/// Locations of runtime-managed data. Nothing here ever lives inside a `.japp` archive.
public enum JAppPaths {
    /// `~/Library/Application Support/JApp`, or `$JAPP_SUPPORT_DIR` when set (used by tests).
    public static var supportDirectory: URL {
        if let override = ProcessInfo.processInfo.environment["JAPP_SUPPORT_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("JApp", isDirectory: true)
    }

    /// Per-app mutable data (`storage.json`), keyed by the manifest `id`, not the file name.
    public static func dataDirectory(forAppID id: String) -> URL {
        supportDirectory.appendingPathComponent("Apps", isDirectory: true)
            .appendingPathComponent(id.lowercased(), isDirectory: true)
    }

    /// Editable copies of app sources created by "Edit Source".
    public static var workspacesDirectory: URL {
        supportDirectory.appendingPathComponent("Workspaces", isDirectory: true)
    }

    /// Which runtime process hosts which app (process-per-app bookkeeping).
    public static var instancesDirectory: URL {
        supportDirectory.appendingPathComponent("Instances", isDirectory: true)
    }
}
