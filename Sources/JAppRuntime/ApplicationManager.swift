import AppKit
import JAppKit

extension Notification.Name {
    /// Posted across processes (DistributedNotificationCenter) with the archive path as object.
    static let jappReloadApp = RuntimeNotification.reload
    static let jappActivateApp = RuntimeNotification.activate
}

/// Decides where an app runs and keeps track of running apps and edit sessions.
///
/// Hosting policy (the default):
/// * JApp Runtime.app runs no app itself: it hands each app to the app's own bundle
///   (`AppBundle`, `--host <path>`), a process with the app's name and icon, its own
///   Dock tile, ⌘Q and crash isolation — and then quits if it has nothing on screen;
/// * an app bundle runs its own app and hands anything else back to JApp Runtime;
/// * opening an app that is already running anywhere brings it to the front.
/// Without app bundles (`JAppAppBundles NO`) the first app runs in the runtime
/// process and further apps get new runtime processes. With `JAppSingleProcess`
/// (or a development build) every app runs in this process and the Dock tile
/// follows the frontmost app.
@MainActor
final class ApplicationManager {
    static let shared = ApplicationManager()

    private(set) var sessions: [AppSession] = []
    private var editors: [EditSessionController] = []
    var forwardConsole = false
    /// Launched with `--develop` (`japp run --develop`): apps run in developer mode.
    var developMode = false
    /// Apps being started in other processes; the runtime must not quit before they are.
    private var pendingLaunches = 0

    /// JApp Runtime starts apps through their app bundles. Not when streaming the
    /// console to a terminal (the app must run in this process for that), and not
    /// for automation unless a test asks for it.
    var usesAppBundles: Bool {
        ProcessIdentity.isRuntimeApp && ProcessIdentity.launcherURL != nil && RuntimeSettings.appBundles
            && !RuntimeSettings.singleProcess && !forwardConsole
            && (!RuntimeSettings.isAutomating || RuntimeSettings.automationAppBundles)
    }

    /// Without app bundles: further apps get runtime processes of their own.
    private var spawnsProcesses: Bool {
        !RuntimeSettings.singleProcess && !RuntimeSettings.isAutomating && ProcessIdentity.isRuntimeApp
    }

    /// Apps may be running in other processes (so look there before starting one).
    private var spansProcesses: Bool {
        ProcessIdentity.isAppBundle || usesAppBundles || spawnsProcesses
    }

    func session(for url: URL) -> AppSession? {
        let path = url.standardizedFileURL.path
        return sessions.first { $0.url.standardizedFileURL.path == path }
    }

    var keySession: AppSession? {
        sessions.first { $0.window.isKeyWindow } ?? sessions.first { $0.window.isMainWindow } ?? (sessions.count == 1 ? sessions.first : nil)
    }

    // MARK: Running apps

    func open(_ url: URL) {
        let url = url.standardizedFileURL
        if let existing = session(for: url) {
            Log.runtime.notice("open \(url.path, privacy: .public): already running here")
            existing.bringToFront()
            return
        }
        if spansProcesses, let pid = InstanceRegistry.process(hosting: url) {
            Log.runtime.notice("open \(url.path, privacy: .public): already running in process \(pid)")
            activate(pid: pid, path: url.path)
            return
        }
        if ProcessIdentity.isAppBundle {
            if sessions.isEmpty { launch(url) } else { handToRuntime(url) }
        } else if usesAppBundles {
            launchThroughAppBundle(url)
        } else if sessions.isEmpty || !spawnsProcesses {
            launch(url)
        } else {
            spawn(url)
        }
    }

    /// Runs the app in this process.
    private func launch(_ url: URL) {
        let package: JAppPackage
        do {
            package = try JAppPackage.load(from: url)
        } catch {
            presentOpenError(error, url: url)
            return
        }
        if let own = ProcessIdentity.appBundle, package.manifest.normalizedID != own.appID {
            // Another app (or this file's id was edited): it belongs in a bundle of its own.
            Log.runtime.notice("\(url.path, privacy: .public) is \(package.manifest.id, privacy: .public), not \(own.appID, privacy: .public): handing it to JApp Runtime")
            handToRuntime(url)
            return
        }
        for warning in package.warnings {
            FileHandle.standardError.write(Data("[\(package.manifest.name)] \(warning)\n".utf8))
        }
        ProcessIdentity.becomeRegularApp()
        guard TrustPolicy.allowsLaunch(of: package) else {
            terminateIfIdle()
            return
        }
        Log.runtime.notice("launch \(package.manifest.id, privacy: .public) from \(url.path, privacy: .public) in process \(getpid())")
        if ProcessIdentity.isAppBundle { AppBundle.recordLaunch(of: url, appID: package.manifest.id) }
        let session = AppSession(package: package, forwardConsole: forwardConsole, developer: developMode)
        session.onClose = { [weak self] in self?.sessionDidClose($0) }
        sessions.append(session)
        session.start()
        InstanceRegistry.update(paths: sessions.map(\.url.path))
        if package.kind == .archive { NSDocumentController.shared.noteNewRecentDocumentURL(url) }
        AppDelegate.shared?.refreshMenus()
    }

    private func spawn(_ url: URL) {
        Log.runtime.notice("spawn a new runtime process for \(url.path, privacy: .public)")
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.arguments = ["--host", url.path]
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, error in
            guard error != nil else { return }
            Task { @MainActor in self.launch(url) }  // could not start a process: host it here
        }
    }

    /// Starts the app through its app bundle (built or refreshed first if needed).
    private func launchThroughAppBundle(_ url: URL) {
        let package: JAppPackage
        do {
            package = try JAppPackage.load(from: url)
        } catch {
            presentOpenError(error, url: url)
            return
        }
        guard TrustPolicy.allowsLaunch(of: package) else {
            terminateIfIdle()
            return
        }
        let bundle: AppBundle
        do {
            guard let runtime = ProcessIdentity.runtimeBundle, let launcher = ProcessIdentity.launcherURL else {
                throw JAppError.io("JApp Runtime.app was not found.")
            }
            bundle = try AppBundle.prepare(for: package.manifest, iconData: package.iconData, launcher: launcher,
                                           entitlements: ProcessIdentity.runtimeResource("JAppRuntime", "entitlements"),
                                           runtimeApp: runtime.bundleURL)
        } catch {
            Log.runtime.error("no app bundle for \(package.manifest.id, privacy: .public): \(error, privacy: .public); running it here")
            launch(url)
            return
        }
        AppBundle.recordLaunch(of: url, appID: package.manifest.id)
        Log.runtime.notice("launch \(package.manifest.id, privacy: .public) through \(bundle.url.path, privacy: .public)")
        let configuration = NSWorkspace.OpenConfiguration()
        // Another file with the same app id is running already: start a second copy.
        configuration.createsNewApplicationInstance = bundle.isRunning
        configuration.arguments = ["--host", url.path] + (developMode ? ["--develop"] : []) + RuntimeSettings.forwardedArguments
        configuration.environment = RuntimeSettings.forwardedEnvironment
        configuration.activates = true
        NSApp.yieldActivation(toApplicationWithBundleIdentifier: bundle.bundleIdentifier)
        pendingLaunches += 1
        NSWorkspace.shared.openApplication(at: bundle.url, configuration: configuration) { _, error in
            Task { @MainActor in
                self.pendingLaunches -= 1
                if let error {
                    Log.runtime.error("could not start \(bundle.url.path, privacy: .public): \(error, privacy: .public); running the app here")
                    self.launch(url)
                } else {
                    self.terminateIfIdle()
                }
            }
        }
    }

    /// In an app bundle: lets JApp Runtime open a file that is not this bundle's app.
    private func handToRuntime(_ url: URL) {
        guard let runtime = ProcessIdentity.runtimeBundle?.bundleURL else {
            presentOpenError(JAppError.io("JApp Runtime.app was not found."), url: url)
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.environment = RuntimeSettings.forwardedEnvironment
        pendingLaunches += 1
        NSWorkspace.shared.open([url], withApplicationAt: runtime, configuration: configuration) { _, error in
            Task { @MainActor in
                self.pendingLaunches -= 1
                if let error { Log.runtime.error("could not hand \(url.path, privacy: .public) to JApp Runtime: \(error, privacy: .public)") }
                self.terminateIfIdle()
            }
        }
    }

    /// In an app bundle started on its own (Dock, Spotlight, Finder): run the app
    /// from the file it last ran from, or ask where that file went.
    func openOwnApp() {
        guard let identity = ProcessIdentity.appBundle else { return }
        if let url = AppBundle.lastLaunched(appID: identity.appID) {
            open(url)
            return
        }
        let missing = JAppError.io("The file of “\(identity.name)” was moved or deleted.")
        if RuntimeSettings.isAutomating {
            Automation.reportFailure(url: AppBundle.directory(forAppID: identity.appID), error: missing)
            return
        }
        let alert = NSAlert()
        alert.messageText = "“\(identity.name)” can’t be found."
        alert.informativeText = "The app’s .japp file was moved somewhere JApp can’t find it, or deleted. If you still have it, locate it to open the app."
        alert.addButton(withTitle: "Locate…")
        alert.addButton(withTitle: "Quit")
        NSApp.activate()
        if alert.runModal() == .alertFirstButtonReturn {
            let panel = NSOpenPanel()
            panel.allowedContentTypes = [AppDelegate.jappType]
            panel.message = "Choose the file of “\(identity.name)”."
            if panel.runModal() == .OK, let url = panel.url {
                open(url)
                return
            }
        }
        terminateIfIdle()
    }

    private func activate(pid: pid_t, path: String) {
        if let app = NSRunningApplication(processIdentifier: pid) { NSApp.yieldActivation(to: app) }
        DistributedNotificationCenter.default().postNotificationName(.jappActivateApp, object: path, userInfo: nil, deliverImmediately: true)
    }

    /// "Save & Run": show the new version, wherever the app is running.
    func runUpdated(_ url: URL) {
        let url = url.standardizedFileURL
        Log.runtime.notice("run updated \(url.path, privacy: .public)")
        if let session = session(for: url) {
            if session.reload() {
                session.bringToFront()
            } else {
                replace(session)
            }
            return
        }
        if spansProcesses, let pid = InstanceRegistry.process(hosting: url) {
            if let app = NSRunningApplication(processIdentifier: pid) { NSApp.yieldActivation(to: app) }
            DistributedNotificationCenter.default().postNotificationName(.jappReloadApp, object: url.path, userInfo: nil, deliverImmediately: true)
            return
        }
        open(url)
    }

    /// Handles reload/activate requests from other runtime processes.
    func handleRemoteRequest(_ name: Notification.Name, path: String) {
        guard let session = session(for: URL(fileURLWithPath: path)) else { return }
        Log.runtime.notice("\(name.rawValue, privacy: .public) request for \(path, privacy: .public)")
        if name == .jappReloadApp, !session.reload() {
            replace(session)
            return
        }
        session.bringToFront()
    }

    /// Swaps a running app for a fresh session (its id changed, so its data store must too).
    /// The new window opens before the old one closes, so the process never runs out of windows.
    private func replace(_ session: AppSession) {
        sessions.removeAll { $0 === session }
        session.onClose = nil
        launch(session.url)
        session.close()
    }

    private func sessionDidClose(_ session: AppSession) {
        sessions.removeAll { $0 === session }
        InstanceRegistry.update(paths: sessions.map(\.url.path))
        if sessions.isEmpty { IconManager.showInDock(nil) }
        AppDelegate.shared?.refreshMenus()
    }

    // MARK: Editing

    func isEditing(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        return editors.contains { $0.archiveURL.standardizedFileURL.path == path }
    }

    func editSource(_ url: URL) {
        let url = url.standardizedFileURL
        if let existing = editors.first(where: { $0.archiveURL.path == url.path }) {
            existing.bringToFront()
            return
        }
        if ProcessIdentity.isAppBundle, session(for: url) == nil {
            editInRuntime(url)  // an app bundle only edits its own app
            return
        }
        ProcessIdentity.becomeRegularApp()
        do {
            guard let controller = try EditSessionController.open(archiveURL: url) else { return terminateIfIdle() }
            controller.onClose = { [weak self] closed in
                self?.editors.removeAll { $0 === closed }
                AppDelegate.shared?.refreshMenus()
            }
            editors.append(controller)
            AppDelegate.shared?.refreshMenus()
        } catch {
            let alert = NSAlert()
            alert.messageText = "The source of “\(url.lastPathComponent)” can’t be opened."
            alert.informativeText = "\(error)"
            alert.alertStyle = .warning
            alert.runModal()
            terminateIfIdle()
        }
    }

    private func editInRuntime(_ url: URL) {
        guard let runtime = ProcessIdentity.runtimeBundle?.bundleURL else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.arguments = ["--edit", url.path]
        configuration.environment = RuntimeSettings.forwardedEnvironment
        NSWorkspace.shared.openApplication(at: runtime, configuration: configuration, completionHandler: nil)
    }

    /// Test hook (automation mode only): drive the Edit Source windows as if a button was clicked.
    func performEditorAction(_ action: String) {
        for editor in editors {
            switch action {
            case "save": editor.save(nil)
            case "saveAndRun": editor.saveAndRun(nil)
            case "close": editor.window?.performClose(nil)
            default: break
            }
        }
    }

    func prepareForTermination() {
        InstanceRegistry.update(paths: [])
        for editor in editors { editor.cleanUpForTermination() }
    }

    // MARK: Errors

    private func presentOpenError(_ error: Error, url: URL) {
        if RuntimeSettings.isAutomating {
            Automation.reportFailure(url: url, error: error)
            return
        }
        ProcessIdentity.becomeRegularApp()
        let alert = NSAlert()
        alert.messageText = "“\(url.lastPathComponent)” can’t be opened."
        alert.informativeText = "\(error)"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        // A broken manifest is fixed by editing the source, so offer that directly.
        let editable: Bool
        switch error {
        case JAppError.invalidManifest, JAppError.manifestMissing, JAppError.entryMissing: editable = true
        default: editable = false
        }
        if editable { alert.addButton(withTitle: "Edit Source…") }
        if alert.runModal() == .alertSecondButtonReturn {
            editSource(url)
        } else {
            terminateIfIdle()
        }
    }

    /// A runtime process with nothing on screen has no reason to stay around.
    func terminateIfIdle() {
        DispatchQueue.main.async {
            if NSApp.windows.allSatisfy({ !$0.isVisible }) && self.sessions.isEmpty && self.editors.isEmpty && self.pendingLaunches == 0 {
                NSApp.terminate(nil)
            }
        }
    }
}
