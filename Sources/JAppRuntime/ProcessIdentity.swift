import AppKit
import JAppKit

/// Which program this process is. The same code (JAppRuntimeCore.dylib) runs as
///
/// * **JApp Runtime.app** — opens `.japp` files and hands each to its app bundle,
///   shows the welcome window and Edit Source windows;
/// * **an app bundle** (`AppBundle`) — runs one app under that app's own name and icon;
/// * **a development build** (`.build/…/JAppRuntime`, no bundle) — runs apps itself.
///
/// Runtime resources (docs, examples, the `japp` tool, the document icon) always
/// come from `runtimeBundle`, never from `Bundle.main`.
enum ProcessIdentity {
    /// The app this process exists for, when it is an app bundle.
    static let appBundle = AppBundle.Identity(infoDictionary: Bundle.main.infoDictionary)
    static var isAppBundle: Bool { appBundle != nil }

    /// This process is JApp Runtime.app itself.
    static var isRuntimeApp: Bool {
        !isAppBundle && Bundle.main.bundleIdentifier == JAppVersion.runtimeBundleIdentifier && Bundle.main.bundleURL.pathExtension == "app"
    }

    /// JApp Runtime.app: the bundle this code was loaded from (nil for development builds).
    static let runtimeBundle: Bundle? = {
        var info = Dl_info()
        if dladdr(#dsohandle, &info) != 0, let path = info.dli_fname {
            // …/JApp Runtime.app/Contents/Frameworks/libJAppRuntimeCore.dylib
            let app = URL(fileURLWithPath: String(cString: path)).resolvingSymlinksInPath()
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            if app.pathExtension == "app", let bundle = Bundle(url: app), bundle.bundleIdentifier == JAppVersion.runtimeBundleIdentifier {
                return bundle
            }
        }
        return Bundle.main.bundleIdentifier == JAppVersion.runtimeBundleIdentifier ? .main : nil
    }()

    /// JApp Runtime's main executable, the launcher copied into app bundles.
    static var launcherURL: URL? { runtimeBundle?.executableURL }

    static func runtimeResource(_ name: String, _ extension: String, subdirectory: String? = nil) -> URL? {
        runtimeBundle?.url(forResource: name, withExtension: `extension`, subdirectory: subdirectory)
    }

    /// JApp Runtime's own icon (in an app bundle, `NSApp.applicationIconImage` is the app's).
    static var runtimeIcon: NSImage? {
        runtimeBundle.map { NSWorkspace.shared.icon(forFile: $0.bundlePath) }
    }

    /// JApp Runtime.app declares LSUIElement: it starts without a Dock tile or menu
    /// bar, because a double-clicked `.japp` is only handed on to its app bundle.
    static var startsHidden: Bool {
        (Bundle.main.object(forInfoDictionaryKey: "LSUIElement") as? Bool) == true
    }

    /// Gives the runtime its Dock tile and menu bar before it shows anything itself.
    @MainActor
    static func becomeRegularApp() {
        guard NSApp.activationPolicy() != .regular else { return }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
    }
}
