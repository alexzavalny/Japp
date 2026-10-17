import AppKit

/// Launch arguments understood by the runtime binary.
///
///     JAppRuntime [--host <file.japp|folder>]… [--edit <file.japp>]… [--console] [--develop] [<file.japp>…]
///
/// `--host` is how one runtime process asks a fresh process to host an app
/// (process-per-app); `japp run` and `japp edit` use the same flags.
/// Single-dash `-Key value` pairs are NSUserDefaults overrides and are skipped here.
struct LaunchArguments {
    var hostURLs: [URL] = []
    var editURLs: [URL] = []
    var console = false
    var develop = false

    static func parse(_ arguments: [String]) -> LaunchArguments {
        var result = LaunchArguments()
        var index = 1
        func url(_ path: String) -> URL { URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL }
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--host" where index + 1 < arguments.count:
                result.hostURLs.append(url(arguments[index + 1]))
                index += 1
            case "--edit" where index + 1 < arguments.count:
                result.editURLs.append(url(arguments[index + 1]))
                index += 1
            case "--console":
                result.console = true
            case "--develop":
                result.develop = true
            default:
                if argument.hasPrefix("-psn_") {
                    break
                } else if argument.hasPrefix("-") {
                    index += 1  // NSUserDefaults argument domain: "-Key value"
                } else {
                    result.hostURLs.append(url(argument))
                }
            }
            index += 1
        }
        return result
    }
}

/// User defaults that tune the runtime. All are optional; set them with
/// `defaults write dev.japp.runtime <Key> <value>` or as `-Key value` arguments.
enum RuntimeSettings {
    private static var defaults: UserDefaults { .standard }

    /// Host every app in this one process instead of one process per app.
    static var singleProcess: Bool { defaults.bool(forKey: "JAppSingleProcess") }
    /// Give `.japp` files in Finder the icon stored inside them (default: on).
    static var setsFinderIcons: Bool { flag("JAppSetFinderIcons", default: true) }
    /// Developer mode for every app: Develop menu and Inspect Element (default: off).
    static var developerMode: Bool { defaults.bool(forKey: "JAppDeveloperMode") }
    /// Bundle identifier of the preferred source editor.
    static var editorBundleID: String? {
        get { defaults.string(forKey: "JAppEditor") }
        set { defaults.set(newValue, forKey: "JAppEditor") }
    }

    // Automation (used by `japp snapshot` and the end-to-end tests).
    static var automationDirectory: URL? {
        defaults.string(forKey: "JAppAutomationDir").map { URL(fileURLWithPath: $0, isDirectory: true) }
    }
    static var automationScript: URL? {
        defaults.string(forKey: "JAppAutomationScript").map { URL(fileURLWithPath: $0) }
    }
    static var automationQuits: Bool { defaults.bool(forKey: "JAppAutomationQuit") }
    /// `"x,y;x,y,alt"`: page points to right-click (⌥ with `alt`); the menus land in report.json.
    static var automationContextMenuPoints: [(point: NSPoint, alt: Bool)] { points("JAppAutomationContextMenus") }
    /// Title of the item to choose in menus shown by `japp.menu.popup` (they close at once either way).
    static var automationMenuChoice: String? { defaults.string(forKey: "JAppAutomationMenuChoice") }
    /// `"x,y;…"`: page points to hit-test (drag region or not).
    static var automationProbePoints: [(point: NSPoint, alt: Bool)] { points("JAppAutomationProbePoints") }

    private static func points(_ key: String) -> [(point: NSPoint, alt: Bool)] {
        (defaults.string(forKey: key) ?? "").split(separator: ";").compactMap { entry in
            let parts = entry.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count >= 2, let x = Double(parts[0]), let y = Double(parts[1]) else { return nil }
            return (NSPoint(x: x, y: y), parts.dropFirst(2).contains("alt"))
        }
    }
    static var isAutomating: Bool { automationDirectory != nil }

    /// Reads a boolean that may come from `defaults write` (a Bool) or from the
    /// command line (`-Key NO`, a String); `bool(forKey:)` understands both.
    static func flag(_ key: String, default value: Bool) -> Bool {
        defaults.object(forKey: key) == nil ? value : defaults.bool(forKey: key)
    }
}
