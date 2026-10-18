import AppKit
import JAppKit
import UniformTypeIdentifiers
import UserNotifications

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation, UNUserNotificationCenterDelegate {
    static var shared: AppDelegate? { NSApp.delegate as? AppDelegate }

    private let manager = ApplicationManager.shared
    private let menu = MainMenu()
    private let arguments = LaunchArguments.parse(CommandLine.arguments)
    private var hasOpenedSomething = false
    private var welcome: WelcomeWindowController?
    private var terminationSource: DispatchSourceSignal?
    private var terminationPending = false

    private var isBundled: Bool { Bundle.main.bundleURL.pathExtension == "app" && Bundle.main.bundleIdentifier != nil }
    static let jappType = UTType(JAppVersion.uniformTypeIdentifier) ?? UTType(filenameExtension: JAppVersion.fileExtension) ?? .data

    // MARK: Launch

    func applicationWillFinishLaunching(_ notification: Notification) {
        menu.install()
        manager.forwardConsole = arguments.console
        manager.developMode = arguments.develop
        // Finder › Services › "Edit JApp Source" (declared as NSServices in Info.plist).
        NSApp.servicesProvider = self
        let distributed = DistributedNotificationCenter.default()
        for name in [Notification.Name.jappReloadApp, .jappActivateApp] {
            distributed.addObserver(self, selector: #selector(remoteRequest(_:)), name: name, object: nil, suspensionBehavior: .deliverImmediately)
        }
        if isBundled { UNUserNotificationCenter.current().delegate = self }
        // `kill`, logout and `pkill` send SIGTERM: quit normally so bookkeeping is cleaned up.
        signal(SIGTERM, SIG_IGN)
        terminationSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        terminationSource?.setEventHandler {
            // terminateLater starts a modal loop; leave the dispatch callback
            // first so asynchronous save decisions can use the main queue.
            RunLoop.main.perform { MainActor.assumeIsolated { NSApp.terminate(nil) } }
        }
        terminationSource?.resume()
        if RuntimeSettings.isAutomating {
            distributed.addObserver(self, selector: #selector(automationRequest(_:)), name: Automation.editorActionNotification,
                                    object: nil, suspensionBehavior: .deliverImmediately)
            distributed.addObserver(self, selector: #selector(automationAppRequest(_:)), name: Automation.appActionNotification,
                                    object: nil, suspensionBehavior: .deliverImmediately)
        }
        if ProcessIdentity.startsHidden {
            // A safety net for windows not covered by an explicit becomeRegularApp().
            NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { ProcessIdentity.becomeRegularApp() }
            }
        }
    }

    @objc private func automationRequest(_ notification: Notification) {
        guard let action = notification.object as? String else { return }
        manager.performEditorAction(action)
    }

    @objc private func automationAppRequest(_ notification: Notification) {
        guard let action = notification.object as? String else { return }
        Automation.performAppAction(action)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let defaultLaunch = notification.userInfo?[NSApplication.launchIsDefaultUserInfoKey] as? Bool ?? false
        let opensNothing = arguments.hostURLs.isEmpty && arguments.editURLs.isEmpty && arguments.newURLs.isEmpty
        if ProcessIdentity.isAppBundle && opensNothing {
            // Started from the Dock, Spotlight or Finder rather than by JApp Runtime.
            hasOpenedSomething = true
            manager.openOwnApp()
        } else if defaultLaunch && opensNothing {
            ProcessIdentity.becomeRegularApp()  // JApp Runtime itself was opened: it will greet the user
        }
        for url in arguments.hostURLs {
            hasOpenedSomething = true
            manager.open(url)
        }
        for url in arguments.editURLs {
            hasOpenedSomething = true
            manager.editSource(url)
        }
        for url in arguments.newURLs {
            hasOpenedSomething = true
            manager.createApp(at: url)
        }
        NSUpdateDynamicServices()
        // Documents and service requests arrive just after launch; only greet
        // the user if JApp Runtime itself was opened.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self, !self.hasOpenedSomething, !NSApp.windows.contains(where: \.isVisible) else { return }
            self.showWelcome()
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.isFileURL && FileManager.default.fileExists(atPath: url.path) {
            hasOpenedSomething = true
            welcome?.close()
            manager.open(url)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if Automation.isFinishing || manager.sessions.isEmpty { return .terminateNow }
        guard !terminationPending else { return .terminateLater }
        terminationPending = true
        Task {
            let allowed = await manager.confirmTermination()
            terminationPending = false
            sender.reply(toApplicationShouldTerminate: allowed)
        }
        return .terminateLater
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag && manager.sessions.isEmpty {
            if ProcessIdentity.isAppBundle { manager.openOwnApp() } else { showWelcome() }
        }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        manager.prepareForTermination()
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    @objc private func remoteRequest(_ notification: Notification) {
        guard let path = notification.object as? String else { return }
        manager.handleRemoteRequest(notification.name, path: path)
    }

    private func showWelcome() {
        ProcessIdentity.becomeRegularApp()
        if welcome == nil { welcome = WelcomeWindowController() }
        welcome?.showWindow(nil)
        NSApp.activate()
        if RuntimeSettings.isAutomating { Automation.renderWindow(welcome?.window, to: "welcome.png") }
    }

    func refreshMenus() {
        menu.setAppName(manager.keySession?.manifest.name ?? ProcessIdentity.appBundle?.name ?? "JApp Runtime")
        menu.setDevelopMenuVisible(manager.keySession?.isDeveloperMode ?? false)
    }

    // MARK: Services

    /// `NSMessage = editJAppSource` in Info.plist.
    @objc func editJAppSource(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        guard !urls.isEmpty else {
            error.pointee = "No .japp file was selected." as NSString
            return
        }
        hasOpenedSomething = true
        welcome?.close()
        for url in urls { manager.editSource(url) }
    }

    // MARK: Notifications

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }

    // MARK: Menu actions

    @objc func openDocument(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [Self.jappType]
        panel.allowsMultipleSelection = true
        panel.message = "Choose a JApp to run."
        guard panel.runModal() == .OK else { return }
        welcome?.close()
        for url in panel.urls { manager.open(url) }
    }

    /// Asks for the new app's name (and where to keep it), then writes a
    /// "Hello, World!" app there and opens its source in the code editor.
    @objc func newApp(_ sender: Any?) {
        let panel = NSSavePanel()
        panel.title = "New App"
        panel.message = "Name your app. It starts as a “Hello, World!” app and opens in your code editor."
        panel.nameFieldLabel = "App Name:"
        panel.nameFieldStringValue = AppTemplate.defaultName
        panel.prompt = "Create"
        panel.allowedContentTypes = [Self.jappType]
        panel.isExtensionHidden = true
        panel.canSelectHiddenExtension = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        // Closed only once the Edit Source window is up: the last window closing quits the runtime.
        if manager.createApp(at: url) { welcome?.close() }
    }

    @objc func editSource(_ sender: Any?) {
        if let session = manager.keySession, session.canEditSource {
            manager.editSource(session.url)
            return
        }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [Self.jappType]
        panel.message = "Choose a JApp whose source you want to edit."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        welcome?.close()
        manager.editSource(url)
    }

    @objc func revealInFinder(_ sender: Any?) {
        guard let session = manager.keySession else { return }
        NSWorkspace.shared.activateFileViewerSelecting([session.url])
    }

    @objc func restoreFinderIcon(_ sender: Any?) {
        guard let session = manager.keySession else { return }
        IconManager.applyFinderIcon(for: session.package, force: true)
    }

    @objc func reloadApp(_ sender: Any?) {
        guard let session = manager.keySession else { return }
        manager.runUpdated(session.url)
    }

    @objc func actualSize(_ sender: Any?) {
        manager.keySession?.webView.pageZoom = 1
        manager.keySession?.pushNativeState()
    }
    @objc func zoomIn(_ sender: Any?) { adjustZoom(by: 0.1) }
    @objc func zoomOut(_ sender: Any?) { adjustZoom(by: -0.1) }

    private func adjustZoom(by delta: CGFloat) {
        guard let webView = manager.keySession?.webView else { return }
        webView.pageZoom = min(3, max(0.5, webView.pageZoom + delta))
        manager.keySession?.pushNativeState()
    }

    @objc func showAbout(_ sender: Any?) {
        guard let session = manager.keySession else { return showRuntimeAbout(sender) }
        let manifest = session.manifest
        var credits = manifest.description ?? ""
        if let author = manifest.author { credits += (credits.isEmpty ? "" : "\n") + "By \(author)" }
        credits += (credits.isEmpty ? "" : "\n\n") + "\(manifest.id)\nRuns on JApp Runtime \(JAppVersion.runtime)"
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: manifest.name,
            .applicationVersion: manifest.version,
            .version: "",
            .applicationIcon: session.icon ?? IconManager.genericIcon,
            .credits: NSAttributedString(string: credits, attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.labelColor]),
        ])
        NSApp.activate()
    }

    @objc func showRuntimeAbout(_ sender: Any?) {
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "JApp Runtime",
            .applicationVersion: JAppVersion.runtime,
            .applicationIcon: ProcessIdentity.runtimeIcon ?? NSImage(named: NSImage.applicationIconName) ?? IconManager.genericIcon,
            .credits: NSAttributedString(string: "Runs .japp applications: single-file HTML, CSS and JavaScript apps you can open, edit and share like documents.",
                                         attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.labelColor]),
        ])
        NSApp.activate()
    }

    @objc func showHelp(_ sender: Any?) {
        if let docs = ProcessIdentity.runtimeResource("CREATING_APPS", "md", subdirectory: "Docs") {
            NSWorkspace.shared.open(docs)
        }
    }

    @objc func openExample(_ sender: Any?) {
        guard let bundled = ProcessIdentity.runtimeResource("Calculator", "japp", subdirectory: "Examples") else { return }
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("JApp Examples", isDirectory: true)
        let target = documents.appendingPathComponent("Calculator.japp")
        do {
            try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: target.path) {
                try FileManager.default.copyItem(at: bundled, to: target)
            }
        } catch {
            NSAlert(error: error).runModal()
            return
        }
        welcome?.close()
        NSWorkspace.shared.activateFileViewerSelecting([target])
        manager.open(target)
    }

    @objc func installCommandLineTool(_ sender: Any?) {
        guard let tool = ProcessIdentity.runtimeBundle?.bundleURL.appendingPathComponent("Contents/Helpers/japp"),
              FileManager.default.isExecutableFile(atPath: tool.path) else { return }
        let link = URL(fileURLWithPath: "/usr/local/bin/japp")
        let alert = NSAlert()
        do {
            if (try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)) != nil || FileManager.default.fileExists(atPath: link.path) {
                try FileManager.default.removeItem(at: link)
            }
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: tool)
            alert.messageText = "The japp command is installed."
            alert.informativeText = "Try “japp help” in Terminal."
        } catch {
            alert.messageText = "The japp command could not be installed automatically."
            alert.informativeText = "Run this in Terminal:\n\nsudo ln -sf '\(tool.path)' /usr/local/bin/japp"
        }
        alert.runModal()
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(revealInFinder(_:)), #selector(reloadApp(_:)), #selector(actualSize(_:)), #selector(zoomIn(_:)), #selector(zoomOut(_:)):
            return manager.keySession != nil
        case #selector(restoreFinderIcon(_:)):
            return manager.keySession?.canEditSource == true
        default:
            return true
        }
    }
}
