import AppKit
import JAppKit

extension Notification.Name {
    /// Posted across processes (DistributedNotificationCenter) with the archive path as object.
    static let jappReloadApp = RuntimeNotification.reload
    static let jappActivateApp = RuntimeNotification.activate
}

/// Decides where an app runs and keeps track of running apps and edit sessions.
///
/// Hosting policy (process-per-app, the default):
/// * the first app opened in a runtime process runs in that process;
/// * any further app is handed to a new runtime process (`--host <path>`), so every
///   app gets its own Dock tile, its own ⌘Q and crash isolation;
/// * opening an app that is already running anywhere brings it to the front.
/// With `JAppSingleProcess` (or when not running from an .app bundle) every app
/// runs in this process and the Dock tile follows the frontmost app.
@MainActor
final class ApplicationManager {
    static let shared = ApplicationManager()

    private(set) var sessions: [AppSession] = []
    private var editors: [EditSessionController] = []
    var forwardConsole = false
    /// Launched with `--develop` (`japp run --develop`): apps run in developer mode.
    var developMode = false

    private var spawnsProcesses: Bool {
        !RuntimeSettings.singleProcess && !RuntimeSettings.isAutomating && Bundle.main.bundleURL.pathExtension == "app"
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
        if spawnsProcesses, let pid = InstanceRegistry.process(hosting: url) {
            Log.runtime.notice("open \(url.path, privacy: .public): already running in process \(pid)")
            activate(pid: pid, path: url.path)
            return
        }
        if sessions.isEmpty || !spawnsProcesses {
            launch(url)
        } else {
            spawn(url)
        }
    }

    private func launch(_ url: URL) {
        let package: JAppPackage
        do {
            package = try JAppPackage.load(from: url)
        } catch {
            presentOpenError(error, url: url)
            return
        }
        for warning in package.warnings {
            FileHandle.standardError.write(Data("[\(package.manifest.name)] \(warning)\n".utf8))
        }
        guard TrustPolicy.allowsLaunch(of: package) else {
            terminateIfIdle()
            return
        }
        Log.runtime.notice("launch \(package.manifest.id, privacy: .public) from \(url.path, privacy: .public) in process \(getpid())")
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
        if spawnsProcesses, let pid = InstanceRegistry.process(hosting: url) {
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
            if NSApp.windows.allSatisfy({ !$0.isVisible }) && self.sessions.isEmpty && self.editors.isEmpty {
                NSApp.terminate(nil)
            }
        }
    }
}
