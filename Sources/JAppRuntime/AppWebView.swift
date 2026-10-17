import AppKit
@preconcurrency import WebKit

/// The web view of one app, with the parts of window behaviour WebKit leaves out:
/// window drag regions and an app-like context menu.
@MainActor
final class AppWebView: WKWebView {
    /// Whether developer items (Inspect Element) belong in context menus.
    var isDeveloperMode: () -> Bool = { false }
    /// Called with every WebKit context menu after filtering (automation).
    var onContextMenu: ((NSMenu) -> Void)?
    /// Titles of the last context menu as WebKit built it, before filtering (automation).
    private(set) var lastUnfilteredMenu: [String] = []

    /// Areas that move the window, and holes in them, in page coordinates (CSS px, top-left origin).
    private(set) var dragRegions: [NSRect] = []
    private(set) var dragExclusions: [NSRect] = []
    /// Modifier keys of the click that opened the last context menu (the event
    /// WebKit hands to `willOpenMenu` does not always carry them).
    private var contextClickModifiers: NSEvent.ModifierFlags = []

    func setDragRegions(_ regions: [NSRect], excluding exclusions: [NSRect]) {
        dragRegions = regions
        dragExclusions = exclusions
    }

    // MARK: Coordinates

    private var scale: CGFloat { max(pageZoom * magnification, 0.01) }

    /// A point in this view → page coordinates.
    func pagePoint(_ point: NSPoint) -> NSPoint {
        NSPoint(x: point.x / scale, y: (isFlipped ? point.y : bounds.height - point.y) / scale)
    }

    /// Page coordinates → a point in this view.
    func viewPoint(fromPage point: NSPoint) -> NSPoint {
        NSPoint(x: point.x * scale, y: isFlipped ? point.y * scale : bounds.height - point.y * scale)
    }

    /// Whether a window-coordinate location lies in a drag region.
    func isInDragRegion(windowLocation: NSPoint) -> Bool {
        guard let window, !window.styleMask.contains(.fullScreen), !dragRegions.isEmpty else { return false }
        let point = pagePoint(convert(windowLocation, from: nil))
        return dragRegions.contains { $0.contains(point) } && !dragExclusions.contains { $0.contains(point) }
    }

    // MARK: Dragging the window

    override func mouseDown(with event: NSEvent) {
        contextClickModifiers = event.modifierFlags  // ⌃-click opens a context menu too
        guard isInDragRegion(windowLocation: event.locationInWindow), let window else {
            return super.mouseDown(with: event)
        }
        if event.clickCount == 2 {
            Self.performTitleBarDoubleClick(on: window)
        } else {
            window.performDrag(with: event)
        }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        if let event, isInDragRegion(windowLocation: event.locationInWindow) { return true }
        return super.acceptsFirstMouse(for: event)
    }

    /// What double-clicking a title bar does, as set in System Settings › Desktop & Dock.
    static func performTitleBarDoubleClick(on window: NSWindow) {
        let defaults = UserDefaults.standard
        switch defaults.string(forKey: "AppleActionOnDoubleClick") {
        case "None": break
        case "Minimize": window.performMiniaturize(nil)
        case "Maximize", "Fill", "Zoom": window.performZoom(nil)
        default:
            if defaults.bool(forKey: "AppleMiniaturizeOnDoubleClick") { window.performMiniaturize(nil) } else { window.performZoom(nil) }
        }
    }

    // MARK: Context menu

    override func rightMouseDown(with event: NSEvent) {
        contextClickModifiers = event.modifierFlags
        super.rightMouseDown(with: event)
    }

    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        super.willOpenMenu(menu, with: event)
        lastUnfilteredMenu = menu.items.map { $0.isSeparatorItem ? "-" : "\($0.title) [\($0.identifier?.rawValue ?? "")]" }
        let option = [event.modifierFlags, contextClickModifiers, NSEvent.modifierFlags].contains { $0.contains(.option) }
        NativeFeel.filter(menu, developer: isDeveloperMode() || option)
        if menu.items.isEmpty {
            // Nothing app-like is left: close the menu the moment it starts tracking.
            nonisolated(unsafe) let empty = menu
            RunLoop.main.perform(inModes: [.eventTracking]) { empty.cancelTrackingWithoutAnimation() }
        }
        onContextMenu?(menu)
    }
}
