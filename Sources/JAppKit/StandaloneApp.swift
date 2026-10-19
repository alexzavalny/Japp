import Foundation

/// A JApp exported as a self-contained Mac app (`japp export`, *File › Export as App…*):
/// the "projector" for Macs that have no JApp Runtime.
///
///     <App Name>.app/Contents/
///       Info.plist                           the app's identity; CFBundleIdentifier is the app id
///       MacOS/<App Name>                     a copy of JApp Runtime's launcher
///       Frameworks/libJAppRuntimeCore.dylib  a copy of the runtime
///       Resources/<App Name>.japp            the app, unchanged
///       Resources/AppIcon.icns
///
/// The launcher loads the library from ../Frameworks before it looks for an installed
/// JApp Runtime, so the app runs on any Mac with the same macOS and CPU the runtime was
/// built for. It runs its embedded `.japp` and nothing else; the signature seals the
/// archive, so there is no Edit Source in it. Like an app bundle (`AppBundle`) it
/// declares no document types, URL schemes or services.
public enum StandaloneApp {
    /// Key in the Info.plist's `JAppApplication` dictionary: the embedded archive's file name.
    public static let archiveKey = "archive"
    public static let libraryName = "libJAppRuntimeCore.dylib"

    /// The parts copied from JApp Runtime.
    public struct Runtime: Sendable {
        public var launcher: URL
        public var library: URL
        /// JApp Runtime's entitlements; with them the app gets the hardened runtime.
        public var entitlements: URL?

        public init(launcher: URL, library: URL, entitlements: URL?) {
            self.launcher = launcher
            self.library = library
            self.entitlements = entitlements
        }

        /// The parts of an installed `JApp Runtime.app`.
        public init(app: URL) throws {
            let contents = app.appendingPathComponent("Contents")
            self.init(launcher: contents.appendingPathComponent("MacOS/JAppRuntime"),
                      library: contents.appendingPathComponent("Frameworks").appendingPathComponent(StandaloneApp.libraryName),
                      entitlements: contents.appendingPathComponent("Resources/JAppRuntime.entitlements"))
            for file in [launcher, library] where !FileManager.default.fileExists(atPath: file.path) {
                throw JAppError.io("“\(app.lastPathComponent)” is not a complete JApp Runtime: \(file.lastPathComponent) is missing.")
            }
            if let entitlements, !FileManager.default.fileExists(atPath: entitlements.path) { self.entitlements = nil }
        }
    }

    public struct Result: Sendable {
        public let url: URL
        public let manifest: Manifest
        /// Bytes on disk, all files together.
        public let size: Int
        public let warnings: [ValidationIssue]
    }

    /// Writes `source` (a `.japp` file or an app folder) as a standalone app at
    /// `destination` (`<Name>.app`). The app is assembled and signed next to the
    /// destination first; an existing app there is only replaced when `replacing`.
    ///
    /// `signingIdentity` "-" signs ad hoc (the default); a "Developer ID Application"
    /// identity makes an app that can be notarized.
    @discardableResult
    public static func export(_ source: URL, to destination: URL, runtime: Runtime, signingIdentity: String = "-",
                              replacing: Bool = false, sign: Bool = true) throws -> Result {
        let fm = FileManager.default
        guard destination.pathExtension == "app" else { throw JAppError.io("The exported app’s name must end in .app.") }
        if isInside(destination, folder: source) {
            // The next `japp pack` of the folder would pack the exported app into the .japp.
            throw JAppError.io("The exported app can’t go inside the app’s own folder.")
        }
        let (archive, package) = try load(source)
        let manifest = package.manifest
        if fm.fileExists(atPath: destination.path) && !replacing {
            throw JAppError.io("“\(destination.path)” already exists.")
        }

        let parent = destination.deletingLastPathComponent()
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        let staging = parent.appendingPathComponent(".\(destination.lastPathComponent).export-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: staging) }
        let built = staging.appendingPathComponent(destination.lastPathComponent, isDirectory: true)
        let contents = built.appendingPathComponent("Contents", isDirectory: true)
        for folder in ["MacOS", "Frameworks", "Resources"] {
            try fm.createDirectory(at: contents.appendingPathComponent(folder), withIntermediateDirectories: true)
        }

        // Written from data rather than copied: extended attributes (a Finder icon,
        // quarantine) are not allowed inside a signed bundle.
        let executable = AppBundle.fileName(for: manifest.name)
        let launcher = contents.appendingPathComponent("MacOS").appendingPathComponent(executable)
        try Data(contentsOf: runtime.launcher).write(to: launcher)
        let library = contents.appendingPathComponent("Frameworks").appendingPathComponent(libraryName)
        try Data(contentsOf: runtime.library).write(to: library)
        for file in [launcher, library] { try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path) }
        let archiveName = executable + "." + JAppVersion.fileExtension
        try archive.write(to: contents.appendingPathComponent("Resources").appendingPathComponent(archiveName))
        let icon = package.iconData.flatMap(ICNS.make(fromImageData:))
        if let icon { try icon.write(to: contents.appendingPathComponent("Resources/AppIcon.icns")) }
        let identity = AppBundle.Identity(appID: manifest.id, name: manifest.name, version: manifest.version,
                                          iconDigest: package.iconData.map(sha256Hex) ?? "",
                                          launcherDigest: try sha256Hex(of: runtime.launcher), runtimePath: "")
        let info = infoDictionary(for: identity, manifest: manifest, executable: executable, archive: archiveName, hasIcon: icon != nil)
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        try Data("APPL????".utf8).write(to: contents.appendingPathComponent("PkgInfo"))

        if sign {
            // Nested code first: the library must carry the same signer as the app that loads it.
            let hardened = runtime.entitlements != nil
            try CodeSigning.sign(library, identity: signingIdentity, hardened: hardened)
            try CodeSigning.sign(built, identity: signingIdentity, hardened: hardened, entitlements: runtime.entitlements)
            try CodeSigning.verify(built)
        }

        if fm.fileExists(atPath: destination.path) {
            let previous = staging.appendingPathComponent("previous.app")
            try AppBundle.rename(destination, to: previous)
            do {
                try AppBundle.rename(built, to: destination)
            } catch {
                try? AppBundle.rename(previous, to: destination)
                throw error
            }
        } else {
            try AppBundle.rename(built, to: destination)
        }
        try? fm.setAttributes([.modificationDate: Date()], ofItemAtPath: destination.path)
        return Result(url: destination, manifest: manifest, size: diskSize(of: destination), warnings: package.warnings)
    }

    static func infoDictionary(for identity: AppBundle.Identity, manifest: Manifest, executable: String, archive: String,
                               hasIcon: Bool) -> [String: Any] {
        var info = AppBundle.infoDictionary(for: identity, executable: executable, hasIcon: hasIcon)
        // A real app of its own: no namespace prefix, no pointer to an installed runtime.
        info["CFBundleIdentifier"] = identity.appID
        info.removeValue(forKey: AppBundle.runtimePathKey)
        var fields = info[AppBundle.infoKey] as? [String: Any] ?? [:]
        fields[archiveKey] = archive
        fields["runtimeVersion"] = JAppVersion.runtime
        info[AppBundle.infoKey] = fields
        if let author = manifest.author, !author.isEmpty { info["NSHumanReadableCopyright"] = author }
        return info
    }

    /// Whether `url` (which need not exist yet) is inside `folder` (false when `folder` is a file).
    public static func isInside(_ url: URL, folder: URL) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue else { return false }
        let root = realPath(folder)
        return realPath(url).hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }

    /// The path with symbolic links resolved (`/tmp` → `/private/tmp`), also for a
    /// path that does not exist yet: its nearest existing folder is resolved.
    private static func realPath(_ url: URL) -> String {
        var existing = url.standardizedFileURL
        var rest: [String] = []
        while !FileManager.default.fileExists(atPath: existing.path), existing.path != "/" {
            rest.insert(existing.lastPathComponent, at: 0)
            existing.deleteLastPathComponent()
        }
        guard let resolved = realpath(existing.path, nil) else { return url.standardizedFileURL.path }
        defer { free(resolved) }
        return rest.reduce(URL(fileURLWithPath: String(cString: resolved))) { $0.appendingPathComponent($1) }.path
    }

    /// The archive to embed, validated: a `.japp` as it is, a folder packed first.
    private static func load(_ source: URL) throws -> (Data, JAppPackage) {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: source.path, isDirectory: &isDirectory) else { throw JAppError.fileNotFound(source) }
        let data: Data
        if isDirectory.boolValue {
            let report = PackageValidator.validate(url: source)
            guard report.isValid else { throw JAppError.invalidManifest(report.issues) }
            data = try Packager.archiveData(for: Packager.collectFiles(in: source))
        } else {
            data = try Data(contentsOf: source)
        }
        let archiveURL = source.deletingPathExtension().appendingPathExtension(JAppVersion.fileExtension)
        return (data, try JAppPackage.load(archiveData: data, url: archiveURL))
    }

    private static func diskSize(of url: URL) -> Int {
        let files = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey])
        var total = 0
        while let file = files?.nextObject() as? URL {
            total += (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        }
        return total
    }
}
