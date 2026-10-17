import AppKit

/// Entry point, called by the launcher (Sources/JAppLauncher/main.c) — the main
/// executable of JApp Runtime.app and of every per-app bundle.
///
/// JApp Runtime has no nib or storyboard: the menu bar and every window are built in code.
@_cdecl("JAppRuntimeMain")
public func runtimeMain(_ argc: Int32, _ argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> Int32 {
    MainActor.assumeIsolated {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        // JApp Runtime.app starts without a Dock tile (LSUIElement): opening a .japp
        // usually only hands it to the app's own bundle. Anything it shows itself
        // makes it a regular app (ProcessIdentity.becomeRegularApp).
        if !ProcessIdentity.startsHidden { application.setActivationPolicy(.regular) }
        withExtendedLifetime(delegate) { application.run() }
    }
    return 0
}
