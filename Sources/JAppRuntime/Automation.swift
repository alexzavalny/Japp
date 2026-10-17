import AppKit
import JAppKit
@preconcurrency import WebKit

/// Headless-friendly hooks used by `japp snapshot` and the end-to-end tests.
///
/// When the `JAppAutomationDir` default is set, the runtime writes, after the
/// app's first page load:
///   report.json   window title/frame, console output, optional script result
///   snapshot.png  what the web view rendered
///   dock-icon.png the image given to the Dock
///   window.png    the whole window: title bar, traffic lights and page
/// `JAppAutomationContextMenus` and `JAppAutomationProbePoints` add right-click
/// menus and drag-region hit tests at given page points (see RuntimeSettings).
/// `JAppAutomationScript` names a JavaScript file run (as an async function body)
/// before the snapshot; its return value lands in `report.json`.
/// `JAppAutomationQuit` makes the runtime quit when done.
@MainActor
enum Automation {
    /// Object: "save", "saveAndRun" or "close" — acts on open Edit Source windows.
    static let editorActionNotification = Notification.Name("dev.japp.runtime.automation.editor")

    /// Writes `edit-report.json`: where the source lives and what changed.
    static func reportEditSession(_ workspace: SourceWorkspace, status: String) {
        guard let directory = RuntimeSettings.automationDirectory else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let report: [String: Any] = [
            "archive": workspace.archiveURL.path,
            "sourceFolder": workspace.sourceURL.path,
            "changes": ((try? workspace.changes()) ?? []).map(\.description),
            "status": status,
            "pid": Int(getpid()),
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? data.write(to: directory.appendingPathComponent("edit-report.json"), options: .atomic)
    }

    /// Renders a window made of AppKit views (title bar included) to a PNG.
    static func renderWindow(_ window: NSWindow?, to name: String) {
        guard let directory = RuntimeSettings.automationDirectory,
              let frameView = window?.contentView?.superview,
              let bitmap = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds) else { return }
        frameView.cacheDisplay(in: frameView.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: directory.appendingPathComponent(name), options: .atomic)
    }

    /// Menus shown by `japp.menu.popup`, for report.json.
    private static var poppedMenus: [[String: Any]] = []

    /// Records a `japp.menu.popup` menu, then picks `JAppAutomationMenuChoice` (if any) and closes it.
    static func menuWillPopUp(_ menu: NSMenu, at pagePoint: NSPoint) {
        poppedMenus.append([
            "x": pagePoint.x, "y": pagePoint.y,
            "items": menu.items.map { $0.isSeparatorItem ? "-" : $0.title },
            "symbols": menu.items.filter { $0.image != nil }.count,
        ])
        let choice = RuntimeSettings.automationMenuChoice
        nonisolated(unsafe) let tracked = menu
        RunLoop.main.perform(inModes: [.eventTracking]) {
            MainActor.assumeIsolated {
                if let choice, let index = tracked.items.firstIndex(where: { $0.title == choice }) {
                    tracked.performActionForItem(at: index)
                }
                tracked.cancelTrackingWithoutAnimation()
            }
        }
    }

    static func report(for session: AppSession) {
        guard let directory = RuntimeSettings.automationDirectory else { return }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 400_000_000)
            var report: [String: Any] = [
                "ok": true,
                "appId": session.manifest.id,
                "name": session.manifest.name,
                "version": session.manifest.version,
                "windowTitle": session.window.title,
                "windowVisible": session.window.isVisible,
                "contentSize": ["width": session.webView.bounds.width, "height": session.webView.bounds.height],
                "location": session.webView.url?.absoluteString ?? "",
                "permissions": session.manifest.permissions.map(\.rawValue).sorted(),
                "pid": Int(getpid()),
            ]
            if let scriptURL = RuntimeSettings.automationScript {
                do {
                    let script = try String(contentsOf: scriptURL, encoding: .utf8)
                    let body = "const __jappResult = await (async () => {\n\(script)\n})();\n"
                        + "return JSON.stringify(__jappResult === undefined ? null : __jappResult);"
                    let value = try await session.webView.callAsyncJavaScript(body, arguments: [:], in: nil, contentWorld: .page)
                    if let json = value as? String, let data = json.data(using: .utf8) {
                        report["scriptResult"] = (try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed)) ?? NSNull()
                    }
                } catch {
                    report["scriptError"] = "\(error)"
                }
                try? await Task.sleep(nanoseconds: 300_000_000)  // let the page repaint
            }
            report["native"] = nativeReport(for: session)
            let menuPoints = RuntimeSettings.automationContextMenuPoints
            if !menuPoints.isEmpty {
                report["contextMenus"] = await contextMenus(at: menuPoints, in: session)
                try? await Task.sleep(nanoseconds: 2_500_000_000)  // let chosen menu actions finish
                report["finalLocation"] = session.webView.url?.absoluteString ?? ""
            }
            report["menus"] = poppedMenus
            report["windowTitle"] = session.window.title
            report["console"] = session.consoleMessages

            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if let snapshot = await snapshot(of: session.webView) {
                writePNG(snapshot, to: directory.appendingPathComponent("snapshot.png"))
                if let window = renderWindow(session.window, content: snapshot, of: session.webView) {
                    writePNG(window, to: directory.appendingPathComponent("window.png"))
                }
            }
            writePNG(NSApp.applicationIconImage, to: directory.appendingPathComponent("dock-icon.png"))
            write(report, to: directory)
            if RuntimeSettings.automationQuits { NSApp.terminate(nil) }
        }
    }

    /// What the native-feel layer is doing: developer mode, title bar metrics, drag regions, menus.
    private static func nativeReport(for session: AppSession) -> [String: Any] {
        let webView = session.webView!
        let state = session.nativeState
        let rect = { (r: NSRect) -> [Double] in [r.minX, r.minY, r.width, r.height].map { Double($0) } }
        var probes: [[String: Any]] = []
        for (point, _) in RuntimeSettings.automationProbePoints {
            let windowPoint = webView.convert(webView.viewPoint(fromPage: point), to: nil)
            let frameView = session.window.contentView?.superview
            let hit = frameView.flatMap { $0.hitTest($0.convert(windowPoint, from: nil)) }
            probes.append(["x": point.x, "y": point.y, "drag": webView.isInDragRegion(windowLocation: windowPoint),
                           "hitView": hit.map { String(describing: type(of: $0)) } ?? "none"])
        }
        let menuBar = (NSApp.mainMenu?.items ?? []).filter { !$0.isHidden }.map { item -> [String: Any] in
            ["title": item.title, "items": (item.submenu?.items ?? []).filter { !$0.isSeparatorItem && !$0.isHidden }.map(\.title)]
        }
        return [
            "developer": session.isDeveloperMode,
            "titlebarHeight": state.titlebarHeight,
            "titlebarInset": state.titlebarInset,
            "fullSizeContent": session.window.styleMask.contains(.fullSizeContentView),
            "titleVisible": session.window.titleVisibility == .visible,
            "contentView": session.window.contentView.map { String(describing: type(of: $0)) } ?? "none",
            "drawsBackground": (webView.value(forKey: "drawsBackground") as? Bool) ?? true,
            "dragRegions": webView.dragRegions.map(rect),
            "dragExclusions": webView.dragExclusions.map(rect),
            "probes": probes,
            "menuBar": menuBar,
        ]
    }

    /// Right-clicks page points and records the context menu WebKit shows (after filtering).
    private static func contextMenus(at points: [(point: NSPoint, alt: Bool)], in session: AppSession) async -> [[String: Any]] {
        final class Capture { var items: [[String: String]]?; var tracked = false }
        let webView = session.webView!
        var results: [[String: Any]] = []
        for (point, alt) in points {
            let capture = Capture()
            webView.onContextMenu = { menu in
                capture.items = menu.items.map { ["title": $0.isSeparatorItem ? "-" : $0.title, "identifier": $0.identifier?.rawValue ?? ""] }
                // Close the menu as soon as it is tracking (this block only runs in that mode).
                nonisolated(unsafe) let tracked = menu
                nonisolated(unsafe) let box = capture
                RunLoop.main.perform(inModes: [.eventTracking]) {
                    box.tracked = true
                    tracked.cancelTrackingWithoutAnimation()
                }
            }
            let windowPoint = webView.convert(webView.viewPoint(fromPage: point), to: nil)
            for type in [NSEvent.EventType.rightMouseDown, .rightMouseUp] {
                if let event = NSEvent.mouseEvent(with: type, location: windowPoint, modifierFlags: alt ? [.option] : [],
                                                  timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: session.window.windowNumber,
                                                  context: nil, eventNumber: 0, clickCount: 1, pressure: type == .rightMouseDown ? 1 : 0) {
                    session.window.sendEvent(event)
                }
            }
            for _ in 0..<30 where capture.items == nil { try? await Task.sleep(nanoseconds: 50_000_000) }
            webView.onContextMenu = nil
            try? await Task.sleep(nanoseconds: 100_000_000)
            results.append(["x": point.x, "y": point.y, "alt": alt, "shown": capture.items != nil, "tracked": capture.tracked,
                            "unfiltered": webView.lastUnfilteredMenu,
                            "items": capture.items ?? []])
        }
        return results
    }

    /// The window as AppKit draws it, with the page snapshot in place and the
    /// title bar (traffic lights) on top, as on screen.
    private static func renderWindow(_ window: NSWindow, content: NSImage, of webView: NSView) -> NSImage? {
        guard let frameView = window.contentView?.superview else { return nil }
        func cache(_ view: NSView) -> (NSBitmapImageRep, NSRect)? {
            guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            return (bitmap, frameView.convert(view.bounds, from: view))
        }
        let titleBar = window.standardWindowButton(.closeButton)?.superview?.superview
        let image = NSImage(size: frameView.bounds.size)
        image.lockFocus()
        window.backgroundColor.setFill()
        frameView.bounds.fill()
        if let (bitmap, rect) = cache(frameView) { bitmap.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil) }
        content.draw(in: frameView.convert(webView.bounds, from: webView))
        if let titleBar, let (bitmap, rect) = cache(titleBar) {
            bitmap.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
        image.unlockFocus()
        return image
    }

    static func reportFailure(url: URL, error: Error) {
        guard let directory = RuntimeSettings.automationDirectory else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        write(["ok": false, "file": url.path, "error": "\(error)"], to: directory)
        if RuntimeSettings.automationQuits { NSApp.terminate(nil) }
    }

    private static func snapshot(of webView: WKWebView) async -> NSImage? {
        await withCheckedContinuation { continuation in
            webView.takeSnapshot(with: nil) { image, _ in continuation.resume(returning: image) }
        }
    }

    private static func write(_ report: [String: Any], to directory: URL) {
        guard let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? data.write(to: directory.appendingPathComponent("report.json"), options: .atomic)
    }

    private static func writePNG(_ image: NSImage, to url: URL) {
        guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: url, options: .atomic)
    }
}
