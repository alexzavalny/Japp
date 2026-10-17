import AppKit
import JAppKit

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
///
/// App bundles have preferences domains of their own (`dev.japp.app.<id>`, used for
/// window frames and the like), so runtime settings are read from JApp Runtime's
/// domain in every process; `-Key value` launch arguments take precedence.
enum RuntimeSettings {
    /// JApp Runtime's preferences (`dev.japp.runtime`).
    static let store: UserDefaults = ProcessIdentity.isAppBundle
        ? UserDefaults(suiteName: JAppVersion.runtimeBundleIdentifier) ?? .standard : .standard

    /// Host every app in this one process instead of one process per app.
    static var singleProcess: Bool { flag("JAppSingleProcess", default: false) }
    /// Run each app through its own app bundle, so it has its own name in the menu bar,
    /// Dock, ⌘-Tab and notifications (default: on).
    static var appBundles: Bool { flag("JAppAppBundles", default: true) }
    /// Give `.japp` files in Finder the icon stored inside them (default: on).
    static var setsFinderIcons: Bool { flag("JAppSetFinderIcons", default: true) }
    /// Developer mode for every app: Develop menu and Inspect Element (default: off).
    static var developerMode: Bool { flag("JAppDeveloperMode", default: false) }
    /// Bundle identifier of the preferred source editor.
    static var editorBundleID: String? {
        get { object("JAppEditor") as? String }
        set { store.set(newValue, forKey: "JAppEditor") }
    }

    // Automation (used by `japp snapshot` and the end-to-end tests).
    static var automationDirectory: URL? {
        (object("JAppAutomationDir") as? String).map { URL(fileURLWithPath: $0, isDirectory: true) }
    }
    static var automationScript: URL? {
        (object("JAppAutomationScript") as? String).map { URL(fileURLWithPath: $0) }
    }
    static var automationQuits: Bool { flag("JAppAutomationQuit", default: false) }
    /// Automation normally runs apps in-process; this tests the app-bundle path instead.
    static var automationAppBundles: Bool { flag("JAppAutomationAppBundles", default: false) }
    /// `"x,y;x,y,alt"`: page points to right-click (⌥ with `alt`); the menus land in report.json.
    static var automationContextMenuPoints: [(point: NSPoint, alt: Bool)] { points("JAppAutomationContextMenus") }
    /// Title of the item to choose in menus shown by `japp.menu.popup` (they close at once either way).
    static var automationMenuChoice: String? { object("JAppAutomationMenuChoice") as? String }
    /// `"x,y;…"`: page points to hit-test (drag region or not).
    static var automationProbePoints: [(point: NSPoint, alt: Bool)] { points("JAppAutomationProbePoints") }

    private static func points(_ key: String) -> [(point: NSPoint, alt: Bool)] {
        (object(key) as? String ?? "").split(separator: ";").compactMap { entry in
            let parts = entry.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count >= 2, let x = Double(parts[0]), let y = Double(parts[1]) else { return nil }
            return (NSPoint(x: x, y: y), parts.dropFirst(2).contains("alt"))
        }
    }
    static var isAutomating: Bool { automationDirectory != nil }

    /// `-JApp… value` launch arguments, passed on when JApp Runtime starts an app
    /// bundle so settings given to `japp run` or a test reach the app.
    static var forwardedArguments: [String] {
        let arguments = CommandLine.arguments
        var forwarded: [String] = []
        var index = 1
        while index + 1 < arguments.count {
            if arguments[index].hasPrefix("-JApp") {
                forwarded += [arguments[index], arguments[index + 1]]
                index += 1
            }
            index += 1
        }
        return forwarded
    }

    /// `JAPP_*` environment variables (such as `JAPP_SUPPORT_DIR`), passed on likewise.
    static var forwardedEnvironment: [String: String] {
        ProcessInfo.processInfo.environment.filter { $0.key.hasPrefix("JAPP_") }
    }

    private static func object(_ key: String) -> Any? {
        UserDefaults.standard.object(forKey: key) ?? store.object(forKey: key)
    }

    /// Reads a boolean that may come from `defaults write` (a Bool) or from the
    /// command line (`-Key NO`, a String), like `UserDefaults.bool(forKey:)`.
    static func flag(_ key: String, default value: Bool) -> Bool {
        switch object(key) {
        case let number as NSNumber: return number.boolValue
        case let string as String: return ["yes", "true"].contains(string.lowercased()) || (Int(string) ?? 0) != 0
        default: return value
        }
    }
}
