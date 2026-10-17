import AppKit
import JAppKit
import WebKit

/// Creates and updates native windows from a manifest's `window` section.
@MainActor
enum WindowManager {
    static func makeWindow(for manifest: Manifest, background: NSColor?) -> NSWindow {
        let options = manifest.window
        var style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable]
        if options.resizable { style.insert(.resizable) }
        if options.titleBarStyle.extendsUnderTitleBar { style.insert(.fullSizeContentView) }

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: options.width, height: options.height),
                              styleMask: style, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.tabbingMode = .disallowed
        window.collectionBehavior.insert(.fullScreenPrimary)
        apply(manifest, to: window, background: background)

        // Remember where the user put the window. The declared size is part of the
        // key, so editing the size in manifest.json takes effect on the next launch.
        let autosaveName = frameAutosaveName(for: manifest)
        if !window.setFrameUsingName(autosaveName) { window.center() }
        window.setFrameAutosaveName(autosaveName)
        return window
    }

    static func apply(_ manifest: Manifest, to window: NSWindow, background: NSColor?) {
        let options = manifest.window
        window.title = manifest.name
        window.contentMinSize = NSSize(width: options.minWidth ?? min(options.width, 200), height: options.minHeight ?? min(options.height, 150))
        window.contentMaxSize = NSSize(width: options.maxWidth ?? .greatestFiniteMagnitude, height: options.maxHeight ?? .greatestFiniteMagnitude)
        if options.resizable { window.styleMask.insert(.resizable) } else { window.styleMask.remove(.resizable) }
        let style = options.titleBarStyle
        window.titlebarAppearsTransparent = style != .default
        window.titleVisibility = style.extendsUnderTitleBar ? .hidden : .visible
        if style.extendsUnderTitleBar { window.styleMask.insert(.fullSizeContentView) } else { window.styleMask.remove(.fullSizeContentView) }
        if style == .hiddenInset {
            // An empty unified toolbar gives the taller title bar with inset traffic lights.
            if window.toolbar == nil { window.toolbar = NSToolbar(identifier: "dev.japp.inset") }
            window.toolbarStyle = .unified
        } else {
            window.toolbar = nil
        }
        if let background { window.backgroundColor = background }
        if style != .default, let background {
            window.appearance = NSAppearance(named: background.isDark ? .darkAqua : .aqua)
        } else {
            window.appearance = nil
        }
    }

    /// Puts the web view into the window, over a system material if the manifest asks for one.
    static func installContent(_ webView: WKWebView, in window: NSWindow, material: WindowOptions.Material?) {
        webView.removeFromSuperview()
        guard let material else {
            window.contentView = webView
            return
        }
        let effect = NSVisualEffectView()
        effect.material = material.visualEffectMaterial
        effect.blendingMode = .behindWindow
        effect.state = .followsWindowActiveState
        window.contentView = effect
        webView.frame = effect.bounds
        webView.autoresizingMask = [.width, .height]
        effect.addSubview(webView)
    }

    /// Where the traffic lights sit when the page extends under the title bar:
    /// the height of the band they are centred in and the width to keep clear (points).
    static func titleBarMetrics(of window: NSWindow, style: WindowOptions.TitleBarStyle) -> (height: CGFloat, inset: CGFloat) {
        guard style.extendsUnderTitleBar, !window.styleMask.contains(.fullScreen),
              let close = window.standardWindowButton(.closeButton), let zoom = window.standardWindowButton(.zoomButton),
              let frameView = close.superview else { return (0, 0) }
        let closeFrame = frameView.convert(close.frame, to: nil)
        let zoomFrame = zoom.superview?.convert(zoom.frame, to: nil) ?? closeFrame
        let centerFromTop = window.frame.height - closeFrame.midY
        return (height: (2 * centerFromTop).rounded(), inset: (zoomFrame.maxX + closeFrame.minX).rounded())
    }

    /// Applies a changed manifest to a running window, resizing it if the declared size changed.
    static func update(_ window: NSWindow, from old: Manifest, to new: Manifest, background: NSColor?) {
        apply(new, to: window, background: background)
        if old.window.width != new.window.width || old.window.height != new.window.height {
            let center = NSPoint(x: window.frame.midX, y: window.frame.midY)
            window.setContentSize(NSSize(width: new.window.width, height: new.window.height))
            window.setFrameOrigin(NSPoint(x: center.x - window.frame.width / 2, y: center.y - window.frame.height / 2))
            window.setFrameAutosaveName(frameAutosaveName(for: new))
        }
    }

    static func frameAutosaveName(for manifest: Manifest) -> String {
        "japp.\(manifest.normalizedID).\(Int(manifest.window.width))x\(Int(manifest.window.height))"
    }
}

extension WindowOptions.Material {
    var visualEffectMaterial: NSVisualEffectView.Material {
        switch self {
        case .sidebar: return .sidebar
        case .window: return .windowBackground
        case .underWindow: return .underWindowBackground
        case .contentBackground: return .contentBackground
        case .headerView: return .headerView
        case .titlebar: return .titlebar
        case .menu: return .menu
        case .popover: return .popover
        case .hud: return .hudWindow
        case .sheet: return .sheet
        }
    }
}

extension NSColor {
    /// Parses `#RGB`, `#RRGGBB` or `#RRGGBBAA` (validated by the manifest parser).
    convenience init?(hex: String) {
        var digits = String(hex.dropFirst())
        if digits.count == 3 { digits = digits.map { "\($0)\($0)" }.joined() }
        if digits.count == 6 { digits += "FF" }
        guard digits.count == 8, let value = UInt64(digits, radix: 16) else { return nil }
        self.init(srgbRed: CGFloat((value >> 24) & 0xFF) / 255, green: CGFloat((value >> 16) & 0xFF) / 255,
                  blue: CGFloat((value >> 8) & 0xFF) / 255, alpha: CGFloat(value & 0xFF) / 255)
    }

    var isDark: Bool {
        guard let rgb = usingColorSpace(.sRGB) else { return false }
        return 0.299 * rgb.redComponent + 0.587 * rgb.greenComponent + 0.114 * rgb.blueComponent < 0.5
    }
}
