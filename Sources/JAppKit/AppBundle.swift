import AppKit
import Foundation

/// The small macOS app bundle that gives one JApp its own identity.
///
/// macOS takes the name in the menu bar, under the Dock tile, in ⌘-Tab, in
/// notifications and in Activity Monitor from the *bundle* of a process, and a
/// bundle has exactly one identity. So JApp Runtime generates one bundle per app id
///
///     ~/Library/Application Support/JApp/AppBundles/<app-id>/
///       <App Name>.app/Contents/Info.plist        name, version, dev.japp.app.<app-id>, icon
///       <App Name>.app/Contents/MacOS/<App Name>  a copy of JApp Runtime's launcher
///       <App Name>.app/Contents/Resources/AppIcon.icns
///       launch.json                               the .japp it last ran (for Dock and Spotlight launches)
///
/// signs it ad hoc and starts the app through it. The bundle holds neither app
/// code (that stays in the .japp) nor runtime code (the launcher loads
/// JAppRuntimeCore.dylib from JApp Runtime.app), and it declares no document
/// types, URL schemes or services, so it never becomes the handler of anything.
public struct AppBundle: Equatable, Sendable {
    /// Bundle identifiers of app bundles: `dev.japp.app.<app-id>`. The prefix keeps an
    /// app from claiming another program's identity (a `.japp` with id `com.apple.finder`
    /// becomes `dev.japp.app.com.apple.finder`).
    public static let identifierPrefix = "dev.japp.app."
    /// Info.plist key with the bundle's `Identity`.
    public static let infoKey = "JAppApplication"
    /// Info.plist key the launcher reads to find JApp Runtime.app.
    public static let runtimePathKey = "JAppRuntimePath"
    /// Bumped when the layout of generated bundles changes, so old ones are rebuilt.
    public static let format = 1

    /// What a bundle was generated from. A bundle whose identity differs from the
    /// expected one is rebuilt before the app is launched through it.
    public struct Identity: Equatable, Sendable {
        public var appID: String
        public var name: String
        public var version: String
        /// SHA-256 of the icon in the archive, "" for none.
        public var iconDigest: String
        /// SHA-256 of the launcher the bundle's executable was copied from.
        public var launcherDigest: String
        public var runtimePath: String
        public var format: Int

        public init(appID: String, name: String, version: String, iconDigest: String, launcherDigest: String,
                    runtimePath: String, format: Int = AppBundle.format) {
            self.appID = appID.lowercased()
            self.name = name
            self.version = version
            self.iconDigest = iconDigest
            self.launcherDigest = launcherDigest
            self.runtimePath = runtimePath
            self.format = format
        }

        /// Reads the identity from an app bundle's Info.plist; nil for any other bundle.
        public init?(infoDictionary info: [String: Any]?) {
            guard let info, let fields = info[AppBundle.infoKey] as? [String: Any],
                  let appID = fields["id"] as? String, Manifest.isValidID(appID) else { return nil }
            self.init(appID: appID, name: info["CFBundleName"] as? String ?? appID,
                      version: info["CFBundleShortVersionString"] as? String ?? "",
                      iconDigest: fields["iconDigest"] as? String ?? "",
                      launcherDigest: fields["launcherDigest"] as? String ?? "",
                      runtimePath: info[AppBundle.runtimePathKey] as? String ?? "",
                      format: fields["format"] as? Int ?? 0)
        }

        var infoFields: [String: Any] {
            ["id": appID, "iconDigest": iconDigest, "launcherDigest": launcherDigest, "format": format]
        }
    }

    public let url: URL
    public let identity: Identity

    public var bundleIdentifier: String { Self.bundleIdentifier(forAppID: identity.appID) }
    public var executableURL: URL {
        url.appendingPathComponent("Contents/MacOS").appendingPathComponent(Self.fileName(for: identity.name))
    }

    // MARK: Locations and names

    /// `~/Library/Application Support/JApp/AppBundles`.
    public static var rootDirectory: URL {
        JAppPaths.supportDirectory.appendingPathComponent("AppBundles", isDirectory: true)
    }

    /// The folder holding the bundle (and launch record) of one app id.
    public static func directory(forAppID id: String, root: URL = rootDirectory) -> URL {
        root.appendingPathComponent(id.lowercased(), isDirectory: true)
    }

    public static func bundleIdentifier(forAppID id: String) -> String {
        identifierPrefix + id.lowercased()
    }

    /// The app's name as a file name: Finder, the Dock and Launch Services show the
    /// bundle's file name, so it should read exactly like the app.
    public static func fileName(for name: String) -> String {
        var cleaned = String(String.UnicodeScalarView(name.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }))
        cleaned = cleaned.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while cleaned.hasPrefix(".") { cleaned.removeFirst() }
        while cleaned.utf8.count > 200 { cleaned.removeLast() }  // file names are limited to 255 bytes
        return cleaned.isEmpty ? "App" : cleaned
    }

    // MARK: Finding bundles

    /// The bundle generated for an app id, if there is one.
    public static func existing(forAppID id: String, root: URL = rootDirectory) -> AppBundle? {
        bundles(in: directory(forAppID: id, root: root)).first { $0.identity.appID == id.lowercased() }
    }

    /// Every generated bundle.
    public static func all(root: URL = rootDirectory) -> [AppBundle] {
        let folders = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        return folders.map { root.appendingPathComponent($0, isDirectory: true) }.flatMap(bundles(in:)).sorted { $0.identity.name.localizedStandardCompare($1.identity.name) == .orderedAscending }
    }

    private static func bundles(in directory: URL) -> [AppBundle] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.filter { $0.hasSuffix(".app") }.sorted().compactMap { name in
            let url = directory.appendingPathComponent(name, isDirectory: true)
            let plist = url.appendingPathComponent("Contents/Info.plist")
            guard let data = try? Data(contentsOf: plist),
                  let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                  let identity = Identity(infoDictionary: info) else { return nil }
            return AppBundle(url: url, identity: identity)
        }
    }

    /// Whether a process is running from this bundle (its files must not change then).
    public var isRunning: Bool {
        let path = url.resolvingSymlinksInPath().path
        return NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).contains {
            !$0.isTerminated && $0.bundleURL?.resolvingSymlinksInPath().path == path
        }
    }

    // MARK: Creating and updating

    /// The bundle to launch `manifest` through: the existing one if it is current
    /// (or running — it is then updated on a later launch), otherwise a fresh build.
    public static func prepare(for manifest: Manifest, iconData: Data?, launcher: URL, entitlements: URL?,
                               runtimeApp: URL, root: URL = rootDirectory) throws -> AppBundle {
        let expected = Identity(appID: manifest.id, name: manifest.name, version: manifest.version,
                                iconDigest: iconData.map(sha256Hex) ?? "", launcherDigest: try sha256Hex(of: launcher),
                                runtimePath: runtimeApp.path)
        if let current = existing(forAppID: manifest.id, root: root) {
            let complete = FileManager.default.isExecutableFile(atPath: current.executableURL.path)
            if (current.identity == expected && complete) || current.isRunning { return current }
        }
        return try build(expected, iconData: iconData, launcher: launcher, entitlements: entitlements, root: root)
    }

    /// Writes the bundle for `identity`, replacing the app id's previous bundle.
    ///
    /// The new contents are assembled and signed in a staging folder first. An
    /// existing bundle keeps its folder (renamed if the app's name changed) and only
    /// has its `Contents` swapped, so a Dock item that refers to it keeps working.
    public static func build(_ identity: Identity, iconData: Data?, launcher: URL, entitlements: URL? = nil,
                             sign: Bool = true, root: URL = rootDirectory) throws -> AppBundle {
        let fm = FileManager.default
        let directory = directory(forAppID: identity.appID, root: root)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let lock = try FolderLock(directory.appendingPathComponent(".lock"))
        defer { lock.unlock() }

        let staging = directory.appendingPathComponent(".staging-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: staging) }
        let fileName = fileName(for: identity.name)
        let built = staging.appendingPathComponent(fileName + ".app", isDirectory: true)
        let contents = built.appendingPathComponent("Contents", isDirectory: true)
        try fm.createDirectory(at: contents.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
        try fm.createDirectory(at: contents.appendingPathComponent("Resources"), withIntermediateDirectories: true)

        try fm.copyItem(at: launcher, to: contents.appendingPathComponent("MacOS").appendingPathComponent(fileName))
        let icon = iconData.flatMap(ICNS.make(fromImageData:))
        if let icon { try icon.write(to: contents.appendingPathComponent("Resources/AppIcon.icns")) }
        let info = infoDictionary(for: identity, executable: fileName, hasIcon: icon != nil)
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        try Data("APPL????".utf8).write(to: contents.appendingPathComponent("PkgInfo"))
        if sign { try codesign(built, entitlements: entitlements) }

        let target = directory.appendingPathComponent(fileName + ".app", isDirectory: true)
        let previous = bundles(in: directory).map(\.url)
        let reused = previous.first { $0.lastPathComponent == target.lastPathComponent } ?? previous.first
        if let reused {
            if reused.lastPathComponent != target.lastPathComponent { try rename(reused, to: target) }
            let oldContents = staging.appendingPathComponent("Contents-previous")
            try rename(target.appendingPathComponent("Contents"), to: oldContents)
            do {
                try rename(contents, to: target.appendingPathComponent("Contents"))
            } catch {
                try? rename(oldContents, to: target.appendingPathComponent("Contents"))
                throw error
            }
        } else {
            try rename(built, to: target)
        }
        for leftover in previous where leftover != reused { try? fm.removeItem(at: leftover) }
        // Finder, the Dock and Launch Services cache bundle details by modification date.
        // (Launch Services registers the bundle when it is first launched.)
        try? fm.setAttributes([.modificationDate: Date()], ofItemAtPath: target.path)
        return AppBundle(url: target, identity: identity)
    }

    static func infoDictionary(for identity: Identity, executable: String, hasIcon: Bool) -> [String: Any] {
        // CFBundleVersion must be numbers and dots; keep the full version for display.
        let numeric = identity.version.prefix { $0.isNumber || $0 == "." }
        var info: [String: Any] = [
            "CFBundleDevelopmentRegion": "en",
            "CFBundleDisplayName": identity.name,
            "CFBundleExecutable": executable,
            "CFBundleIdentifier": bundleIdentifier(forAppID: identity.appID),
            "CFBundleInfoDictionaryVersion": "6.0",
            "CFBundleName": identity.name,
            "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": identity.version,
            "CFBundleVersion": numeric.isEmpty ? "1" : String(numeric),
            "LSMinimumSystemVersion": "14.0",
            "NSHighResolutionCapable": true,
            "NSPrincipalClass": "NSApplication",
            "NSSupportsAutomaticTermination": false,
            "NSSupportsSuddenTermination": false,
            runtimePathKey: identity.runtimePath,
            infoKey: identity.infoFields,
        ]
        if hasIcon { info["CFBundleIconFile"] = "AppIcon" }
        return info
    }

    /// Ad-hoc signature, so the bundle's Info.plist and icon are sealed and macOS
    /// treats it as one consistent app. With JApp Runtime's entitlements the bundle
    /// gets the same hardened runtime as JApp Runtime.app.
    private static func codesign(_ bundle: URL, entitlements: URL?) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        var arguments = ["--force", "--sign", "-", "--timestamp=none"]
        if let entitlements { arguments += ["--options", "runtime", "--entitlements", entitlements.path] }
        process.arguments = arguments + [bundle.path]
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        let output = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw JAppError.io("codesign failed: \(String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))")
        }
    }

    /// rename(2): atomic, and unlike FileManager.moveItem it allows a change of case only.
    private static func rename(_ source: URL, to destination: URL) throws {
        guard Darwin.rename(source.path, destination.path) == 0 else {
            throw JAppError.io("Could not move \(source.lastPathComponent) to \(destination.path): \(String(cString: strerror(errno)))")
        }
    }

    /// Unregisters the bundle from Launch Services and deletes its folder.
    public func remove() throws {
        Self.unregister(url)
        try FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    @discardableResult
    static func unregister(_ url: URL) -> Bool {
        let tool = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
        guard FileManager.default.isExecutableFile(atPath: tool) else { return false }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = ["-u", url.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    // MARK: Launch record

    /// Remembers which file the app last ran from, so launching the bundle on its
    /// own (from the Dock, Spotlight or Finder) opens it. A bookmark finds the file
    /// again after it is moved or renamed.
    public static func recordLaunch(of url: URL, appID: String, root: URL = rootDirectory) {
        let directory = directory(forAppID: appID, root: root)
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        var record: [String: Any] = ["path": url.standardizedFileURL.path]
        if let bookmark = try? url.bookmarkData() { record["bookmark"] = bookmark.base64EncodedString() }
        if let data = try? JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: directory.appendingPathComponent("launch.json"), options: .atomic)
        }
    }

    /// The file the app last ran from, if it (or the file it moved to) still exists.
    public static func lastLaunched(appID: String, root: URL = rootDirectory) -> URL? {
        let file = directory(forAppID: appID, root: root).appendingPathComponent("launch.json")
        guard let data = try? Data(contentsOf: file),
              let record = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let path = record["path"] as? String, FileManager.default.fileExists(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        var stale = false
        if let encoded = record["bookmark"] as? String, let bookmark = Data(base64Encoded: encoded),
           let url = try? URL(resolvingBookmarkData: bookmark, bookmarkDataIsStale: &stale),
           FileManager.default.fileExists(atPath: url.path) {
            return url.standardizedFileURL
        }
        return nil
    }
}

/// An exclusive `flock` on a file, so two runtime processes never build the same bundle at once.
private struct FolderLock {
    private let descriptor: Int32

    init(_ url: URL) throws {
        descriptor = open(url.path, O_CREAT | O_RDWR, 0o644)
        guard descriptor >= 0, flock(descriptor, LOCK_EX) == 0 else {
            throw JAppError.io("Could not lock \(url.deletingLastPathComponent().path).")
        }
    }

    func unlock() {
        flock(descriptor, LOCK_UN)
        close(descriptor)
    }
}
