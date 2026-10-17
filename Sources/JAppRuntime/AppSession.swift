import AppKit
import JAppKit
@preconcurrency import WebKit

/// One running app: its package, window, web view, bridge and storage.
///
/// Sessions are independent of each other (separate WebKit data store, storage
/// namespace, bridge and origin), which keeps the door open to stronger process
/// isolation; by default each runtime process hosts exactly one session.
@MainActor
final class AppSession: NSObject {
    let url: URL
    private(set) var package: JAppPackage
    private(set) var icon: NSImage?
    private(set) var window: NSWindow!
    private(set) var webView: AppWebView!
    private(set) lazy var storage = KeyValueStore(appID: manifest.normalizedID)

    private let schemeHandler: ArchiveSchemeHandler
    private var bridge: NativeBridge!
    private var consoleForwarder: ConsoleForwarder?
    private let forwardsConsole: Bool
    private let launchedForDevelopment: Bool
    private var hasShownWindow = false
    private var hasReportedLoad = false
    private(set) var consoleMessages: [[String: String]] = []

    var onClose: ((AppSession) -> Void)?

    var manifest: Manifest { package.manifest }
    var backgroundColor: NSColor? { manifest.window.backgroundColor.flatMap(NSColor.init(hex:)) }
    var canEditSource: Bool { package.kind == .archive }

    /// Developer mode adds the Develop menu (Reload, zoom) and Inspect Element.
    var isDeveloperMode: Bool {
        launchedForDevelopment || RuntimeSettings.developerMode || package.kind == .directory
            || ApplicationManager.shared.isEditing(url)
    }

    /// Window state as the page sees it (see `NativeFeel`).
    var nativeState: NativeFeel.State {
        var state = NativeFeel.State()
        state.developer = isDeveloperMode
        guard let window else { return state }
        state.active = !hasShownWindow || window.isMainWindow
        state.fullScreen = window.styleMask.contains(.fullScreen)
        let metrics = WindowManager.titleBarMetrics(of: window, style: manifest.window.titleBarStyle)
        let zoom = Double(webView?.pageZoom ?? 1)
        state.titlebarHeight = Double(metrics.height) / zoom
        state.titlebarInset = Double(metrics.inset) / zoom
        return state
    }

    var appInfo: [String: Any] {
        [
            "id": manifest.id,
            "name": manifest.name,
            "version": manifest.version,
            "description": manifest.description ?? "",
            "permissions": manifest.permissions.map(\.rawValue).sorted(),
        ]
    }

    init(package: JAppPackage, forwardConsole: Bool, developer: Bool = false) {
        self.url = package.url
        self.package = package
        self.schemeHandler = ArchiveSchemeHandler(package: package)
        self.forwardsConsole = forwardConsole
        self.launchedForDevelopment = developer || forwardConsole
        super.init()

        icon = IconManager.image(for: package)
        bridge = NativeBridge(session: self)
        if forwardConsole || RuntimeSettings.isAutomating { consoleForwarder = ConsoleForwarder(session: self) }
        webView = WebViewFactory.makeWebView(session: self, schemeHandler: schemeHandler, bridge: bridge, console: consoleForwarder)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.isDeveloperMode = { [weak self] in self?.isDeveloperMode ?? false }

        window = WindowManager.makeWindow(for: manifest, background: backgroundColor)
        WindowManager.installContent(webView, in: window, material: manifest.window.material)
        window.delegate = self
        if package.kind == .archive { window.representedURL = url }
        // The native-feel script carries window metrics, so it is installed once the window exists.
        WebViewFactory.installUserScripts(in: webView.configuration.userContentController, session: self, console: consoleForwarder != nil)
    }

    // MARK: Lifecycle

    func start() {
        IconManager.showInDock(icon)
        webView.load(URLRequest(url: schemeHandler.entryURL))
        // Show the window once the page has painted, to avoid a white flash,
        // but never leave the user waiting on a slow page.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.showWindow() }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            IconManager.applyFinderIcon(for: self.package)
        }
    }

    func showWindow() {
        guard !hasShownWindow, window != nil else { return }
        hasShownWindow = true
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        pushNativeState()
    }

    /// Tells the page about window state changes (active, full screen, title bar metrics).
    func pushNativeState() {
        webView?.evaluateJavaScript(NativeFeel.updateScript(nativeState), completionHandler: nil)
    }

    func bringToFront() {
        showWindow()
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    /// Re-reads the app from disk and loads the new version in the same window.
    /// Returns false if the app's identity changed, in which case the caller
    /// must replace this session (a new id means a new storage namespace).
    @discardableResult
    func reload() -> Bool {
        let fresh: JAppPackage
        do {
            fresh = try JAppPackage.load(from: url)
        } catch {
            let alert = NSAlert()
            alert.messageText = "“\(manifest.name)” could not be reloaded."
            alert.informativeText = "\(error)\n\nThe previous version keeps running."
            alert.alertStyle = .warning
            Task { _ = await runAlert(alert) }
            return true
        }
        guard fresh.manifest.normalizedID == manifest.normalizedID else { return false }
        Log.runtime.notice("reload \(fresh.manifest.id, privacy: .public) \(fresh.archiveDigest ?? "", privacy: .public)")

        let old = manifest
        package = fresh
        schemeHandler.replacePackage(fresh)
        WindowManager.update(window, from: old, to: fresh.manifest, background: backgroundColor)
        if old.window.material != fresh.manifest.window.material {
            WindowManager.installContent(webView, in: window, material: fresh.manifest.window.material)
        }
        WebViewFactory.applyBackground(to: webView, session: self)
        WebViewFactory.installUserScripts(in: webView.configuration.userContentController, session: self, console: consoleForwarder != nil)
        icon = IconManager.image(for: fresh)
        IconManager.showInDock(icon)
        IconManager.applyFinderIcon(for: fresh)
        hasReportedLoad = false
        webView.load(URLRequest(url: schemeHandler.entryURL))
        AppDelegate.shared?.refreshMenus()
        return true
    }

    func close() {
        window.performClose(nil)
    }

    private func tearDown() {
        let controller = webView.configuration.userContentController
        controller.removeAllScriptMessageHandlers()
        controller.removeAllUserScripts()
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        onClose?(self)
    }

    // MARK: Console

    func recordConsole(level: String, message: String) {
        consoleMessages.append(["level": level, "message": message])
        if consoleMessages.count > 500 { consoleMessages.removeFirst() }
        if forwardsConsole {
            let line = "[\(manifest.name)] \(level == "log" ? "" : level + ": ")\(message)\n"
            FileHandle.standardError.write(Data(line.utf8))
        }
    }

    // MARK: Sheets

    func runSheet(_ panel: NSSavePanel) async -> NSApplication.ModalResponse {
        showWindow()
        return await withCheckedContinuation { continuation in
            panel.beginSheetModal(for: window) { continuation.resume(returning: $0) }
        }
    }

    func runAlert(_ alert: NSAlert) async -> NSApplication.ModalResponse {
        showWindow()
        return await withCheckedContinuation { continuation in
            alert.beginSheetModal(for: window) { continuation.resume(returning: $0) }
        }
    }
}

// MARK: - Window

extension AppSession: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        tearDown()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        // In single-process mode the shared Dock tile follows the frontmost app.
        IconManager.showInDock(icon)
        AppDelegate.shared?.refreshMenus()
    }

    func windowDidBecomeMain(_ notification: Notification) { pushNativeState() }
    func windowDidResignMain(_ notification: Notification) { pushNativeState() }
    func windowDidEnterFullScreen(_ notification: Notification) { pushNativeState() }
    func windowDidExitFullScreen(_ notification: Notification) { pushNativeState() }
}

// MARK: - Navigation policy

extension AppSession: WKNavigationDelegate {
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if action.shouldPerformDownload { return decisionHandler(.download) }
        guard let url = action.request.url, let scheme = url.scheme?.lowercased() else { return decisionHandler(.cancel) }
        let isMainFrame = action.targetFrame?.isMainFrame ?? true
        let userInitiated = action.navigationType == .linkActivated

        switch scheme {
        case ArchiveSchemeHandler.scheme:
            // Stay inside the app's own origin.
            decisionHandler(url.host?.lowercased() == manifest.normalizedID ? .allow : .cancel)
        case "about":
            decisionHandler(url.absoluteString == "about:blank" || url.absoluteString == "about:srcdoc" ? .allow : .cancel)
        case "data", "blob":
            decisionHandler(isMainFrame ? .cancel : .allow)
        case "http", "https":
            if isMainFrame {
                // Links to the web open in the user's browser, never inside the app window.
                if userInitiated || action.targetFrame == nil { NSWorkspace.shared.open(url) }
                decisionHandler(.cancel)
            } else {
                decisionHandler(manifest.has(.network) ? .allow : .cancel)
            }
        case "mailto", "tel", "sms", "facetime":
            if userInitiated { NSWorkspace.shared.open(url) }
            decisionHandler(.cancel)
        default:
            decisionHandler(.cancel)
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        decisionHandler(response.canShowMIMEType ? .allow : .download)
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        download.delegate = self
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        download.delegate = self
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        pushNativeState()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        pushNativeState()
        showWindow()
        guard !hasReportedLoad else { return }
        hasReportedLoad = true
        if RuntimeSettings.isAutomating { Automation.report(for: self) }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        reportLoadFailure(error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        reportLoadFailure(error)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        recordConsole(level: "error", message: "The web content process terminated; reloading.")
        webView.load(URLRequest(url: schemeHandler.entryURL))
    }

    private func reportLoadFailure(_ error: Error) {
        let nsError = error as NSError
        // Cancelled loads and policy-blocked navigations are expected.
        if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled { return }
        if nsError.domain == "WebKitErrorDomain" && nsError.code == 102 { return }
        recordConsole(level: "error", message: "Load failed: \(nsError.localizedDescription)")
        showWindow()
    }
}

// MARK: - Downloads (`<a download>`, blobs): always through a save panel

extension AppSession: WKDownloadDelegate {
    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String,
                  completionHandler: @escaping (URL?) -> Void) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedFilename
        Task {
            guard await runSheet(panel) == .OK, let url = panel.url else { return completionHandler(nil) }
            try? FileManager.default.removeItem(at: url)  // the user already confirmed replacing it
            completionHandler(url)
        }
    }
}

// MARK: - Web UI: alert/confirm/prompt, <input type=file>, window.open

extension AppSession: WKUIDelegate {
    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        let alert = makeAlert(message)
        alert.addButton(withTitle: "OK")
        Task { _ = await runAlert(alert); completionHandler() }
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let alert = makeAlert(message)
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        Task { completionHandler(await runAlert(alert) == .alertFirstButtonReturn) }
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) {
        let alert = makeAlert(prompt)
        let field = NSTextField(string: defaultText ?? "")
        field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        Task { completionHandler(await runAlert(alert) == .alertFirstButtonReturn ? field.stringValue : nil) }
    }

    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.canChooseFiles = true
        Task { completionHandler(await runSheet(panel) == .OK ? panel.urls : nil) }
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        // window.open / target=_blank: web pages go to the browser; apps get one window.
        if let url = action.request.url, ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
            NSWorkspace.shared.open(url)
        }
        return nil
    }

    func webViewDidClose(_ webView: WKWebView) {
        close()
    }

    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin, initiatedByFrame frame: WKFrameInfo,
                 type: WKMediaCaptureType, decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        // Camera and microphone are not part of the JApp permission model yet.
        decisionHandler(.deny)
    }

    private func makeAlert(_ message: String) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = manifest.name
        alert.informativeText = message
        alert.icon = icon
        return alert
    }
}
