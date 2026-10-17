import AppKit

/// Which runtime process hosts which app, so a second double-click activates the
/// running copy instead of starting another, and `japp save --run` can find it.
/// One small JSON file per process in `~/Library/Application Support/JApp/Instances/`;
/// entries of processes that are gone are pruned on lookup.
public enum InstanceRegistry {
    private static var ownFile: URL { JAppPaths.instancesDirectory.appendingPathComponent("\(getpid()).json") }

    /// Records the apps hosted by this process (an empty list removes the record).
    public static func update(paths: [String]) {
        guard !paths.isEmpty else {
            try? FileManager.default.removeItem(at: ownFile)
            return
        }
        try? FileManager.default.createDirectory(at: JAppPaths.instancesDirectory, withIntermediateDirectories: true)
        let record: [String: Any] = ["pid": Int(getpid()), "paths": paths]
        if let data = try? JSONSerialization.data(withJSONObject: record) {
            try? data.write(to: ownFile, options: .atomic)
        }
    }

    /// The runtime process (other than this one) hosting the app at `url`, if any.
    public static func process(hosting url: URL) -> pid_t? {
        let path = url.standardizedFileURL.path
        let files = (try? FileManager.default.contentsOfDirectory(at: JAppPaths.instancesDirectory, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let record = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let pid = (record["pid"] as? Int).map(pid_t.init), pid != getpid() else { continue }
            guard isRuntime(pid) else {
                try? FileManager.default.removeItem(at: file)
                continue
            }
            if (record["paths"] as? [String])?.contains(path) == true { return pid }
        }
        return nil
    }

    private static func isRuntime(_ pid: pid_t) -> Bool {
        guard let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated else { return false }
        return app.bundleIdentifier == JAppVersion.runtimeBundleIdentifier
    }
}

/// Cross-process requests between runtime processes and the `japp` tool,
/// sent through `DistributedNotificationCenter` with the archive path as object.
public enum RuntimeNotification {
    /// Reload the app at this path in whichever process hosts it, and bring it to the front.
    public static let reload = Notification.Name("dev.japp.runtime.reload")
    /// Bring the app at this path to the front.
    public static let activate = Notification.Name("dev.japp.runtime.activate")
}
