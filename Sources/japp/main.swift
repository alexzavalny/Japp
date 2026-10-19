import AppKit
import Foundation
import JAppKit

// `japp` — create, validate, pack, run and edit JApps from the command line.

let usage = HelpGuide.usage

/// The command being run, so a usage mistake can show that command's synopsis.
var activeCommand: HelpGuide.Command?

/// This executable, symbolic links resolved. (`CommandLine.arguments[0]` is just
/// "japp" when the shell found it on the PATH.)
let executableURL = (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])).resolvingSymlinksInPath()

struct CLIError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

// MARK: - Argument parsing

struct Arguments {
    var positional: [String] = []
    var options: [String: String] = [:]
    var flags: Set<String> = []

    init(_ raw: [String], valueOptions: Set<String>, aliases: [String: String] = [:]) throws {
        var index = 0
        while index < raw.count {
            var argument = raw[index]
            if let alias = aliases[argument] { argument = alias }
            if argument.hasPrefix("--") {
                var name = String(argument.dropFirst(2))
                var inlineValue: String?
                if let equals = name.firstIndex(of: "=") {
                    inlineValue = String(name[name.index(after: equals)...])
                    name = String(name[..<equals])
                }
                if valueOptions.contains(name) {
                    if let inlineValue {
                        options[name] = inlineValue
                    } else {
                        guard index + 1 < raw.count else { throw CLIError("--\(name) needs a value") }
                        options[name] = raw[index + 1]
                        index += 1
                    }
                } else {
                    flags.insert(name)
                }
            } else {
                positional.append(argument)
            }
            index += 1
        }
    }

    func path(_ index: Int, _ what: String) throws -> URL {
        guard positional.indices.contains(index) else {
            guard let command = activeCommand else { throw CLIError("missing \(what)\n\n\(usage)") }
            throw CLIError("missing \(what)\n\nusage: \(command.synopsis)\nMore: japp help \(command.name)")
        }
        return fileURL(positional[index])
    }
}

func fileURL(_ path: String) -> URL {
    URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
}

func printError(_ message: String) {
    FileHandle.standardError.write(Data((message.hasSuffix("\n") ? message : message + "\n").utf8))
}

func printIssues(_ issues: [ValidationIssue]) {
    for issue in issues { print("  \(issue)") }
}

func byteCount(_ bytes: Int) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
}

// MARK: - Runtime discovery

/// Finds JApp Runtime: $JAPP_RUNTIME, the app this tool is bundled in, the
/// installed app, or (for development) a runtime binary next to this tool.
func locateRuntime() -> (app: URL?, executable: URL)? {
    let fm = FileManager.default
    func fromApp(_ app: URL) -> (URL?, URL)? {
        let executable = app.appendingPathComponent("Contents/MacOS/JAppRuntime")
        return fm.isExecutableFile(atPath: executable.path) ? (app, executable) : nil
    }
    if let override = ProcessInfo.processInfo.environment["JAPP_RUNTIME"], !override.isEmpty {
        let url = fileURL(override)
        return url.pathExtension == "app" ? fromApp(url) : (fm.isExecutableFile(atPath: url.path) ? (nil, url) : nil)
    }
    let me = executableURL
    let maybeApp = me.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    if maybeApp.pathExtension == "app", let found = fromApp(maybeApp) { return found }
    if let installed = NSWorkspace.shared.urlForApplication(withBundleIdentifier: JAppVersion.runtimeBundleIdentifier),
       let found = fromApp(installed) { return found }
    for candidate in ["/Applications/JApp Runtime.app", "~/Applications/JApp Runtime.app"] {
        if let found = fromApp(fileURL(candidate)) { return found }
    }
    let sibling = me.deletingLastPathComponent().appendingPathComponent("JAppRuntime")
    if fm.isExecutableFile(atPath: sibling.path) { return (nil, sibling) }
    return nil
}

func requireRuntime() throws -> (app: URL?, executable: URL) {
    guard let runtime = locateRuntime() else {
        throw CLIError("JApp Runtime was not found. Build and install it with Scripts/install.sh, or set JAPP_RUNTIME.")
    }
    return runtime
}

@discardableResult
func execute(_ executable: String, _ arguments: [String], wait: Bool = true) throws -> Int32 {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    try process.run()
    guard wait else { return 0 }
    process.waitUntilExit()
    return process.terminationStatus
}

// MARK: - Commands

func cmdPack(_ raw: [String]) throws {
    let args = try Arguments(raw, valueOptions: ["output"], aliases: ["-o": "--output"])
    let folder = try args.path(0, "app folder")
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue else {
        throw CLIError("“\(folder.path)” is not a folder")
    }
    let output = args.options["output"].map(fileURL)
        ?? fileURL(FileManager.default.currentDirectoryPath).appendingPathComponent(folder.lastPathComponent + ".japp")
    guard output.pathExtension == JAppVersion.fileExtension else { throw CLIError("the output file must end in .japp") }
    do {
        let result = try Packager.pack(directory: folder, to: output)
        print("Packed \(result.manifest.name) \(result.manifest.version) (\(result.manifest.id))")
        print("  \(result.fileCount) files, \(byteCount(result.archiveSize)) → \(output.path)")
        printIssues(result.warnings)
    } catch JAppError.invalidManifest(let issues) {
        printError("“\(folder.lastPathComponent)” is not a valid app:")
        printIssues(issues)
        throw CLIError("nothing was written")
    }
}

func cmdUnpack(_ raw: [String]) throws {
    let args = try Arguments(raw, valueOptions: [])
    let file = try args.path(0, ".japp file")
    let archive: ZipArchive
    do { archive = try ZipArchive(url: file) } catch { throw CLIError("\(error)") }
    let prefix = JAppPackage.rootPrefix(of: archive) ?? ""
    let destination = args.positional.count > 1
        ? fileURL(args.positional[1])
        : fileURL(FileManager.default.currentDirectoryPath).appendingPathComponent(file.deletingPathExtension().lastPathComponent)
    let existing = (try? FileManager.default.contentsOfDirectory(atPath: destination.path)) ?? []
    if !existing.isEmpty && !args.flags.contains("force") {
        throw CLIError("“\(destination.path)” is not empty (use --force to extract into it anyway)")
    }
    let files = try Packager.extract(archive, rootPrefix: prefix, to: destination)
    print("Extracted \(files.count) files to \(destination.path)")
    print("Repack with: japp pack \"\(destination.path)\" --output \"\(file.path)\"")
}

func cmdValidate(_ raw: [String]) throws {
    let args = try Arguments(raw, valueOptions: [])
    let target = try args.path(0, ".japp file or folder")
    let report = PackageValidator.validate(url: target)
    if report.isValid, let manifest = report.manifest {
        print("✓ \(target.lastPathComponent): \(manifest.name) \(manifest.version) (\(manifest.id)) is valid — \(report.files.count) files")
        printIssues(report.warnings)
    } else {
        print("✗ \(target.lastPathComponent) is not valid:")
        printIssues(report.issues)
        exit(1)
    }
}

func cmdInfo(_ raw: [String]) throws {
    let args = try Arguments(raw, valueOptions: [])
    let target = try args.path(0, ".japp file or folder")
    let package: JAppPackage
    do { package = try JAppPackage.load(from: target) } catch { throw CLIError("\(error)") }
    let manifest = package.manifest
    let dataDirectory = JAppPaths.dataDirectory(forAppID: manifest.id)
    let files = package.resources.filePaths
    let quarantined = getxattr(target.path, "com.apple.quarantine", nil, 0, 0, 0) > 0

    if args.flags.contains("json") {
        let info: [String: Any] = [
            "id": manifest.id, "name": manifest.name, "version": manifest.version,
            "description": manifest.description ?? "", "entry": manifest.entry, "icon": manifest.icon ?? "",
            "permissions": manifest.permissions.map(\.rawValue).sorted(), "files": files,
            "window": ["width": manifest.window.width, "height": manifest.window.height, "resizable": manifest.window.resizable],
            "dataDirectory": dataDirectory.path, "quarantined": quarantined, "sha256": package.archiveDigest ?? "",
            "appBundle": AppBundle.existing(forAppID: manifest.id)?.url.path ?? "",
        ]
        let data = try JSONSerialization.data(withJSONObject: info, options: [.prettyPrinted, .sortedKeys])
        print(String(decoding: data, as: UTF8.self))
        return
    }
    print("\(manifest.name) \(manifest.version)")
    print("  id:          \(manifest.id)")
    if let description = manifest.description { print("  description: \(description)") }
    print("  entry:       \(manifest.entry)")
    print("  icon:        \(manifest.icon ?? "(none)")")
    print("  window:      \(Int(manifest.window.width))×\(Int(manifest.window.height))\(manifest.window.resizable ? ", resizable" : "")")
    let permissions = manifest.permissions.map(\.rawValue).sorted()
    print("  permissions: \(permissions.isEmpty ? "(none)" : permissions.joined(separator: ", "))")
    print("  data:        \(dataDirectory.path)")
    if let bundle = AppBundle.existing(forAppID: manifest.id) { print("  app bundle:  \(bundle.url.path)") }
    if package.kind == .archive {
        print("  archive:     \(byteCount((try? target.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)), sha256 \(package.archiveDigest?.prefix(16) ?? "")…")
        if quarantined { print("  quarantined: yes (downloaded; JApp Runtime will ask before the first launch)") }
    }
    print("  files (\(files.count)):")
    for file in files { print("    \(file)") }
    printIssues(package.warnings)
}

func cmdRun(_ raw: [String]) throws {
    let args = try Arguments(raw, valueOptions: [])
    let target = try args.path(0, ".japp file or folder")
    guard FileManager.default.fileExists(atPath: target.path) else { throw CLIError("“\(target.path)” does not exist") }
    let runtime = try requireRuntime()
    if args.flags.contains("console") {
        // Run in the foreground so the app's console output streams to this terminal.
        print("Running \(target.lastPathComponent); console output follows. Quit the app (⌘Q) or press Ctrl-C to stop.")
        fflush(stdout)
        let status = try execute(runtime.executable.path, ["--host", target.path, "--console", "-JAppSingleProcess", "YES"])
        exit(status)
    }
    if args.flags.contains("develop") {
        // A process of its own, so developer mode does not leak into apps that are already running.
        try execute(runtime.executable.path, ["--host", target.path, "--develop"], wait: false)
        return
    }
    if let app = runtime.app {
        try execute("/usr/bin/open", ["-a", app.path, target.path])
    } else {
        try execute(runtime.executable.path, ["--host", target.path], wait: false)
    }
}

func cmdEdit(_ raw: [String]) throws {
    let args = try Arguments(raw, valueOptions: [])
    let target = try args.path(0, ".japp file")
    guard FileManager.default.fileExists(atPath: target.path) else { throw CLIError("“\(target.path)” does not exist") }
    // Create (or resume) the workspace here so its path can be printed; the
    // runtime's Edit Source window picks up the same workspace.
    let workspace: SourceWorkspace
    do { workspace = try SourceWorkspace.open(archiveURL: target).0 } catch { throw CLIError("\(error)") }
    print("Source folder: \(workspace.sourceURL.path)")
    if args.flags.contains("no-window") {
        print("Edit the files there, then run: japp save \"\(target.path)\" --run")
        return
    }
    let runtime = try requireRuntime()
    if let app = runtime.app {
        try execute("/usr/bin/open", ["-n", "-a", app.path, "--args", "--edit", target.path])
    } else {
        try execute(runtime.executable.path, ["--edit", target.path], wait: false)
    }
    print("Edit the files, then click Save (or Save & Run) in the JApp window, or run: japp save \"\(target.path)\" --run")
}

func cmdSave(_ raw: [String]) throws {
    let args = try Arguments(raw, valueOptions: [])
    let target = try args.path(0, ".japp file")
    guard let workspace = SourceWorkspace.existing(for: target) else {
        throw CLIError("no source is being edited for “\(target.lastPathComponent)”. Start with: japp edit \"\(target.path)\"")
    }
    let result: SourceWorkspace.SaveResult
    do {
        result = try workspace.save(overwritingExternalChanges: args.flags.contains("force"))
    } catch WorkspaceError.archiveChangedOnDisk {
        throw CLIError("“\(target.lastPathComponent)” was changed by another program since editing began. Use --force to replace it with the workspace (the replaced file is kept in \(workspace.backupsURL.path)).")
    } catch WorkspaceError.invalidSource(let issues) {
        printError("“\(target.lastPathComponent)” was not saved; fix these problems in \(workspace.sourceURL.path):")
        printIssues(issues)
        exit(1)
    }
    let changed = result.changes.isEmpty ? "no changes" : result.changes.map(\.description).joined(separator: ", ")
    print("Saved \(target.lastPathComponent) (\(changed))")
    printIssues(result.warnings)
    if let package = try? JAppPackage.load(from: target) { FinderIcon.apply(for: package) }
    if args.flags.contains("close") {
        try? workspace.remove()
        print("Closed the editing session (removed \(workspace.rootURL.path))")
    }

    if args.flags.contains("run") {
        if InstanceRegistry.process(hosting: target) != nil {
            DistributedNotificationCenter.default().postNotificationName(RuntimeNotification.reload, object: target.path,
                                                                         userInfo: nil, deliverImmediately: true)
            print("Requested reload of the running app")
        } else {
            try cmdRun([target.path])
        }
    }
}

func cmdSnapshot(_ raw: [String]) throws {
    let args = try Arguments(raw, valueOptions: ["output", "script", "eval", "timeout"], aliases: ["-o": "--output"])
    let target = try args.path(0, ".japp file or folder")
    guard FileManager.default.fileExists(atPath: target.path) else { throw CLIError("“\(target.path)” does not exist") }
    let runtime = try requireRuntime()
    let output = args.options["output"].map(fileURL)
        ?? fileURL(FileManager.default.currentDirectoryPath).appendingPathComponent(target.deletingPathExtension().lastPathComponent + ".png")
    let timeout = Double(args.options["timeout"] ?? "") ?? 30

    let work = FileManager.default.temporaryDirectory.appendingPathComponent("japp-snapshot-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: work) }

    var runtimeArguments = ["--host", target.path, "-JAppAutomationDir", work.path, "-JAppAutomationQuit", "YES",
                            "-JAppSingleProcess", "YES", "-JAppSetFinderIcons", "NO"]
    if let script = args.options["script"] {
        runtimeArguments += ["-JAppAutomationScript", fileURL(script).path]
    } else if let source = args.options["eval"] {
        let script = work.appendingPathComponent("eval.js")
        try Data(source.utf8).write(to: script)
        runtimeArguments += ["-JAppAutomationScript", script.path]
    }

    let process = Process()
    process.executableURL = runtime.executable
    process.arguments = runtimeArguments
    process.standardError = FileHandle.nullDevice
    try process.run()
    let deadline = Date().addingTimeInterval(timeout)
    while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.1) }
    if process.isRunning {
        process.terminate()
        throw CLIError("the app did not finish loading within \(Int(timeout)) seconds")
    }

    let reportURL = work.appendingPathComponent("report.json")
    guard let data = try? Data(contentsOf: reportURL),
          let report = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw CLIError("the runtime produced no report (exit status \(process.terminationStatus))")
    }
    let snapshot = work.appendingPathComponent("snapshot.png")
    if FileManager.default.fileExists(atPath: snapshot.path) {
        try? FileManager.default.removeItem(at: output)
        try FileManager.default.copyItem(at: snapshot, to: output)
    }
    print(String(decoding: try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]), as: UTF8.self))
    if FileManager.default.fileExists(atPath: output.path) { printError("snapshot: \(output.path)") }
    let errors = (report["console"] as? [[String: String]] ?? []).filter { $0["level"] == "error" }
    if report["ok"] as? Bool != true || report["scriptError"] != nil || !errors.isEmpty { exit(1) }
}

func cmdRestoreIcon(_ raw: [String]) throws {
    let args = try Arguments(raw, valueOptions: [])
    guard !args.positional.isEmpty else { throw CLIError("missing .japp file") }
    var failed = false
    for path in args.positional {
        let url = fileURL(path)
        if args.flags.contains("remove") {
            FinderIcon.remove(from: url)
            print("Removed the custom icon from \(url.lastPathComponent)")
            continue
        }
        do {
            let package = try JAppPackage.load(from: url)
            switch FinderIcon.apply(for: package, force: true) {
            case .applied, .alreadyCurrent: print("Restored the icon of \(url.lastPathComponent)")
            case .noIcon, .removed: print("\(url.lastPathComponent) has no icon in its manifest")
            case .failed: failed = true; printError("Could not set the icon of \(url.lastPathComponent)")
            }
        } catch {
            failed = true
            printError("\(url.lastPathComponent): \(error)")
        }
    }
    if failed { exit(1) }
}

func cmdStorage(_ raw: [String]) throws {
    let args = try Arguments(raw, valueOptions: [])
    guard let target = args.positional.first else { throw CLIError("missing app (a .japp file, folder or app id)") }
    let id: String
    if FileManager.default.fileExists(atPath: fileURL(target).path) {
        do { id = try JAppPackage.load(from: fileURL(target)).manifest.id } catch { throw CLIError("\(error)") }
    } else {
        guard Manifest.isValidID(target) else { throw CLIError("“\(target)” is neither a file nor an app id") }
        id = target
    }
    let store = KeyValueStore(appID: id)
    if args.flags.contains("clear") {
        try store.clear()
        print("Cleared japp.storage for \(id). (localStorage/IndexedDB live in WebKit's data store and are not affected.)")
        return
    }
    print("japp.storage for \(id): \(store.fileURL.path)")
    let keys = try store.keys()
    if keys.isEmpty { print("  (empty)") }
    for key in keys {
        let value = try store.get(key) ?? "null"
        print("  \(key) = \(value.count > 200 ? String(value.prefix(200)) + "…" : value)")
    }
}

// MARK: - japp bundles

func cmdBundles(_ raw: [String]) throws {
    let args = try Arguments(raw, valueOptions: [])
    switch args.positional.first ?? "list" {
    case "list":
        let bundles = AppBundle.all()
        if bundles.isEmpty { print("No app bundles yet. JApp Runtime makes one the first time an app runs.") }
        for bundle in bundles {
            let identity = bundle.identity
            print("\(identity.name) \(identity.version) (\(identity.appID))\(bundle.isRunning ? " — running" : "")")
            print("  bundle: \(bundle.url.path)")
            print("  runs:   \(AppBundle.lastLaunched(appID: identity.appID)?.path ?? "(its .japp file was moved or deleted)")")
        }
    case "clean":
        var removed = 0
        for bundle in AppBundle.all() where AppBundle.lastLaunched(appID: bundle.identity.appID) == nil && !bundle.isRunning {
            try bundle.remove()
            print("Removed \(bundle.identity.name) (\(bundle.identity.appID)): its .japp file is gone")
            removed += 1
        }
        if removed == 0 { print("Nothing to clean: the .japp file of every app bundle still exists.") }
    case "remove":
        guard args.positional.count >= 2 else { throw CLIError("missing app id or .japp file") }
        let target = args.positional[1]
        let id: String
        if FileManager.default.fileExists(atPath: fileURL(target).path) {
            do { id = try JAppPackage.load(from: fileURL(target)).manifest.id } catch { throw CLIError("\(error)") }
        } else {
            id = target
        }
        guard let bundle = AppBundle.existing(forAppID: id) else { throw CLIError("there is no app bundle for \(id)") }
        guard !bundle.isRunning else { throw CLIError("\(bundle.identity.name) is running; quit it first") }
        try bundle.remove()
        print("Removed the app bundle of \(bundle.identity.name). JApp Runtime makes it again the next time the app runs; the app's data is kept.")
    default:
        throw CLIError("unknown action “\(args.positional[0])”: use list, clean or remove")
    }
}

// MARK: - japp export

func cmdExport(_ raw: [String]) throws {
    let args = try Arguments(raw, valueOptions: ["output", "sign"], aliases: ["-o": "--output"])
    let source = try args.path(0, ".japp file or folder")
    guard FileManager.default.fileExists(atPath: source.path) else { throw CLIError("“\(source.path)” does not exist") }
    let installed = try requireRuntime()
    let runtime: StandaloneApp.Runtime
    if let app = installed.app {
        do { runtime = try StandaloneApp.Runtime(app: app) } catch { throw CLIError("\(error)") }
    } else {
        // A development build: the library sits next to the runtime binary. Without
        // JApp Runtime's entitlements the app is signed without the hardened runtime.
        let library = installed.executable.deletingLastPathComponent().appendingPathComponent(StandaloneApp.libraryName)
        guard FileManager.default.fileExists(atPath: library.path) else { throw CLIError("\(StandaloneApp.libraryName) was not found next to \(installed.executable.path)") }
        runtime = StandaloneApp.Runtime(launcher: installed.executable, library: library, entitlements: nil)
    }

    let package: JAppPackage
    do { package = try JAppPackage.load(from: source) } catch { throw CLIError("\(error)") }
    let fileName = AppBundle.fileName(for: package.manifest.name) + ".app"
    var output = args.options["output"].map(fileURL) ?? fileURL(FileManager.default.currentDirectoryPath).appendingPathComponent(fileName)
    if args.options["output"] == nil, StandaloneApp.isInside(output, folder: source) {
        output = source.deletingLastPathComponent().appendingPathComponent(fileName)  // `japp export .`: next to the folder
    }
    var isDirectory: ObjCBool = false
    if output.pathExtension != "app", FileManager.default.fileExists(atPath: output.path, isDirectory: &isDirectory), isDirectory.boolValue {
        output.appendPathComponent(fileName)  // --output names a folder to export into
    }
    guard output.pathExtension == "app" else { throw CLIError("the output must end in .app (or be an existing folder)") }
    if FileManager.default.fileExists(atPath: output.path) && !args.flags.contains("force") {
        throw CLIError("“\(output.path)” already exists (use --force to replace it)")
    }

    let identity = args.options["sign"] ?? "-"
    let result: StandaloneApp.Result
    do {
        result = try StandaloneApp.export(source, to: output, runtime: runtime, signingIdentity: identity, replacing: true)
    } catch JAppError.invalidManifest(let issues) {
        printError("“\(source.lastPathComponent)” is not a valid app:")
        printIssues(issues)
        throw CLIError("nothing was written")
    } catch {
        throw CLIError("\(error)")
    }
    let manifest = result.manifest
    print("Exported \(manifest.name) \(manifest.version) (\(manifest.id)) → \(result.url.path)")
    print("  \(byteCount(result.size)), JApp Runtime \(JAppVersion.runtime) inside; runs on macOS 14 or later\(architectures(of: runtime.library))")
    printIssues(result.warnings)
    if identity == "-" {
        print("  Signed ad hoc: on another Mac, the first open is blocked until the user allows it in")
        print("  System Settings › Privacy & Security (Open Anyway). To share it widely, export with")
        print("  --sign \"Developer ID Application: …\" and notarize it (xcrun notarytool).")
    } else {
        print("  Signed as \(identity). Notarize it before sharing: xcrun notarytool submit … --wait, then xcrun stapler staple.")
    }
}

/// ", Apple silicon only" and the like, from the library's Mach-O header.
func architectures(of library: URL) -> String {
    guard let handle = try? FileHandle(forReadingFrom: library), let header = try? handle.read(upToCount: 8), header.count == 8 else { return "" }
    let magic = header.prefix(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
    let cpu = header.suffix(4).reversed().reduce(UInt32(0)) { $0 << 8 | UInt32($1) }  // little-endian thin Mach-O
    switch magic {
    case 0xCFFA_EDFE: return cpu == 0x0100_000C ? " (Apple silicon only)" : cpu == 0x0100_0007 ? " (Intel only)" : ""
    case 0xCAFE_BABE, 0xCAFE_BABF: return " (Apple silicon and Intel)"
    default: return ""
    }
}

// MARK: - japp new

func cmdNew(_ raw: [String]) throws {
    let args = try Arguments(raw, valueOptions: ["id", "dir"])
    guard let name = args.positional.first?.trimmingCharacters(in: .whitespaces), !name.isEmpty else {
        throw CLIError("missing app name, e.g. japp new \"Todo List\"")
    }
    let id = args.options["id"] ?? AppTemplate.suggestedID(forName: name)
    guard Manifest.isValidID(id) else { throw CLIError("“\(id)” is not a valid app id (use reverse-DNS form, e.g. com.example.todo)") }

    let parent = args.options["dir"].map(fileURL) ?? fileURL(FileManager.default.currentDirectoryPath)
    let folder = parent.appendingPathComponent(name)
    if FileManager.default.fileExists(atPath: folder.path) { throw CLIError("“\(folder.path)” already exists") }

    let manifest = try AppTemplate.createFolder(at: folder, name: name, id: id)
    print("Created \(folder.path) (\(manifest.id))")
    print("  Try it now:   japp run \"\(folder.path)\" --console")
    print("  Package it:   japp pack \"\(folder.path)\" --output \"\(name).japp\"")
}

// MARK: - japp help

func cmdHelp(_ raw: [String]) throws {
    guard let subject = raw.first(where: { !$0.hasPrefix("-") }) else {
        print(HelpGuide.overview(helpEnvironment()))
        return
    }
    if subject == "all" {
        var parts = [HelpGuide.overview(helpEnvironment())]
        parts += HelpGuide.commands.map(HelpGuide.page)
        parts += HelpGuide.topics.map { topic in (try? topicText(topic)) ?? "\(topic.file): not found (it ships inside JApp Runtime)." }
        print(parts.joined(separator: "\n\n" + String(repeating: "─", count: 96) + "\n\n"))
    } else if let command = HelpGuide.command(named: subject) {
        print(HelpGuide.page(for: command))
    } else if let topic = HelpGuide.topic(named: subject) {
        print(try topicText(topic))
    } else {
        throw CLIError("""
            there is no help for “\(subject)”.
              commands: \(HelpGuide.commands.map(\.name).joined(separator: ", "))
              topics:   \(HelpGuide.topics.map(\.name).joined(separator: ", ")), all
            """)
    }
}

func topicText(_ topic: HelpGuide.Topic) throws -> String {
    guard let docs = documentationDirectory(),
          let text = try? String(contentsOf: docs.appendingPathComponent(topic.file), encoding: .utf8) else {
        throw CLIError("\(topic.file) was not found. It ships inside JApp Runtime (Contents/Resources/Docs); install it with Scripts/install.sh.")
    }
    return text.trimmingCharacters(in: .newlines)
}

/// The documentation that belongs to this japp: in the app it is bundled in, in the
/// source checkout of a development build, or else in the installed JApp Runtime.
func documentationDirectory() -> URL? {
    let fm = FileManager.default
    func docs(in folder: URL) -> URL? {
        let docs = folder.appendingPathComponent("Docs")
        return fm.fileExists(atPath: docs.appendingPathComponent("API.md").path) ? docs : nil
    }
    let app = executableURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    if app.pathExtension == "app", let found = docs(in: app.appendingPathComponent("Contents/Resources")) { return found }
    var folder = executableURL.deletingLastPathComponent()
    for _ in 0..<5 {  // .build/<triple>/debug/japp → the checkout
        if fm.fileExists(atPath: folder.appendingPathComponent("Package.swift").path), let found = docs(in: folder) { return found }
        folder.deleteLastPathComponent()
    }
    return locateRuntime()?.app.flatMap { docs(in: $0.appendingPathComponent("Contents/Resources")) }
}

func helpEnvironment() -> HelpGuide.Environment {
    let fm = FileManager.default
    let onPath = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":")
        .map { ((String($0) as NSString).expandingTildeInPath as NSString).appendingPathComponent("japp") }
        .first { fm.isExecutableFile(atPath: $0) }
    let runtime = locateRuntime()
    let docs = documentationDirectory()
    let examplesFolder = docs?.deletingLastPathComponent().appendingPathComponent("Examples")
    let examples = examplesFolder.flatMap { try? fm.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil, options: .skipsHiddenFiles) }?
        .sorted { $0.lastPathComponent < $1.lastPathComponent } ?? []
    return HelpGuide.Environment(
        executable: executableURL.path,
        pathCommand: onPath,
        pathCommandIsThis: onPath.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath() == executableURL } ?? false,
        runtime: runtime?.app ?? runtime?.executable,
        runtimeVersion: runtime?.app.flatMap { Bundle(url: $0)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String },
        docsDirectory: docs,
        examples: examples,
        supportDirectory: JAppPaths.supportDirectory)
}

// MARK: - Main

let commandLine = Array(CommandLine.arguments.dropFirst())
guard let command = commandLine.first else {
    print(usage)
    exit(0)
}
let rest = Array(commandLine.dropFirst())
activeCommand = HelpGuide.command(named: command)
if let activeCommand, activeCommand.name != "help", rest.contains("--help") || rest.contains("-h") {
    print(HelpGuide.page(for: activeCommand))
    exit(0)
}
do {
    switch command {
    case "new": try cmdNew(rest)
    case "pack": try cmdPack(rest)
    case "unpack", "extract": try cmdUnpack(rest)
    case "validate", "check": try cmdValidate(rest)
    case "info": try cmdInfo(rest)
    case "run", "open": try cmdRun(rest)
    case "edit": try cmdEdit(rest)
    case "save": try cmdSave(rest)
    case "snapshot", "screenshot": try cmdSnapshot(rest)
    case "restore-icon": try cmdRestoreIcon(rest)
    case "storage": try cmdStorage(rest)
    case "bundles", "bundle": try cmdBundles(rest)
    case "export": try cmdExport(rest)
    case "help", "-h", "--help": try cmdHelp(rest)
    case "version", "--version", "-v": print("japp \(JAppVersion.runtime)")
    default:
        printError("unknown command “\(command)”\n\n\(usage)")
        exit(64)
    }
} catch {
    printError("japp: \(error)")
    exit(1)
}
