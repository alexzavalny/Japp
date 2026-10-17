import AppKit
import JAppKit

/// What makes a web page behave like a Mac app rather than a web page.
///
/// * A default stylesheet: no text selection outside text fields, the arrow
///   cursor, no dragging of images and links, no rubber-banding of the whole
///   page, the system font. Every rule has zero specificity (`:where`), so any
///   rule in the app's own CSS wins.
/// * Window state for CSS: `data-japp-window="active|inactive"`,
///   `data-japp-fullscreen`, `--japp-titlebar-height`, `--japp-titlebar-inset`.
/// * Context menus only where macOS shows one (text fields, selected text),
///   without browser items such as Reload or Open Link (see `filter`).
/// * Window drag regions (`data-japp-drag-region`), reported to `AppWebView`.
enum NativeFeel {
    /// The state pushed to the page whenever it changes.
    struct State {
        var active = true
        var fullScreen = false
        /// Height of the band the traffic lights sit in, when the page extends under it (CSS px).
        var titlebarHeight: Double = 0
        /// Width to keep clear on the left for the traffic lights (CSS px).
        var titlebarInset: Double = 0
        var developer = false

        var json: String {
            let object: [String: Any] = ["active": active, "fullScreen": fullScreen, "titlebarHeight": titlebarHeight,
                                         "titlebarInset": titlebarInset, "developer": developer]
            let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
            return String(decoding: data, as: UTF8.self)
        }
    }

    static let styleSheet = """
    :where(html) {
      -webkit-user-select: none;
      cursor: default;
      overscroll-behavior: none;
      font-family: system-ui, -apple-system, sans-serif;
    }
    :where(input, textarea, [contenteditable]:not([contenteditable="false"]), [data-selectable]) {
      -webkit-user-select: text;
      cursor: auto;
    }
    :where(img:not([draggable="true"]), a:not([draggable="true"])) {
      -webkit-user-drag: none;
    }
    """

    /// Applies a `State` to the document (also used for later updates).
    static let applyFunction = #"""
    function (s) {
      const r = document.documentElement;
      if (!r) return;
      r.setAttribute("data-japp-window", s.active ? "active" : "inactive");
      r.toggleAttribute("data-japp-fullscreen", s.fullScreen);
      r.style.setProperty("--japp-titlebar-height", s.titlebarHeight + "px");
      r.style.setProperty("--japp-titlebar-inset", s.titlebarInset + "px");
    }
    """#

    static func updateScript(_ state: State) -> String {
        "(\(applyFunction))(\(state.json));"
    }

    /// Injected at document start, after the bridge script.
    static func script(state: State) -> String {
        let css = (try? JSONSerialization.data(withJSONObject: styleSheet, options: [.fragmentsAllowed]))
            .map { String(decoding: $0, as: UTF8.self) } ?? "\"\""
        return template
            .replacingOccurrences(of: "__JAPP_STYLE__", with: css)
            .replacingOccurrences(of: "__JAPP_APPLY__", with: applyFunction)
            .replacingOccurrences(of: "__JAPP_STATE__", with: state.json)
    }

    private static let template = #"""
    (() => {
      "use strict";
      const state = __JAPP_STATE__;
      const root = document.documentElement;

      // Native defaults, first in the cascade so the app's own CSS overrides them.
      if (root) {
        const style = document.createElement("style");
        style.setAttribute("data-japp", "native-defaults");
        style.textContent = __JAPP_STYLE__;
        root.prepend(style);
      }
      (__JAPP_APPLY__)(state);

      // Context menus: macOS shows them on text fields and selected text, not on
      // buttons, labels or empty space. Apps that call preventDefault (for
      // japp.menu.popup) are unaffected; ⌥ or developer mode shows WebKit's menu.
      const textTypes = new Set(["", "text", "search", "email", "url", "tel", "password", "number"]);
      const isTextField = (el) => el.isContentEditable || el.tagName === "TEXTAREA" ||
        (el.tagName === "INPUT" && textTypes.has((el.getAttribute("type") || "").toLowerCase()));
      window.addEventListener("contextmenu", (event) => {
        if (event.defaultPrevented || state.developer || event.altKey) return;
        const node = event.target;
        const el = node instanceof Element ? node : node && node.parentElement;
        if (!el) return;
        if (isTextField(el) || el.closest("video, audio")) return;
        const selection = window.getSelection();
        if (selection && !selection.isCollapsed && selection.toString().trim() && selection.containsNode(el, true)) return;
        event.preventDefault();
      });

      // Window drag regions: elements marked data-japp-drag-region move the window
      // like a title bar; controls inside them stay clickable. Without any, a page
      // that extends under the title bar gets a drag band of the title bar's height.
      const channel = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.japp;
      if (!channel) return;
      const DRAG = "[data-japp-drag-region]:not([data-japp-drag-region='false'])";
      const NO_DRAG = "a[href], button, input, select, textarea, label, summary, video, audio, iframe, " +
        "[contenteditable]:not([contenteditable='false']), [role='button'], [role='link'], [role='tab'], " +
        "[role='checkbox'], [role='switch'], [role='menuitem'], [data-japp-no-drag], [data-japp-drag-region='false']";
      const round = (n) => Math.round(n * 100) / 100;
      const rectOf = (el) => {
        const r = el.getBoundingClientRect();
        return r.width > 0 && r.height > 0 ? [round(r.left), round(r.top), round(r.width), round(r.height)] : null;
      };
      const collect = (elements, filter) => {
        const out = [];
        for (const el of elements) {
          const r = rectOf(el);
          if (r && (!filter || filter(r))) out.push(r);
          if (out.length >= 256) break;
        }
        return out;
      };
      let last = "", scheduled = false;
      const measure = () => {
        scheduled = false;
        let drag = collect(document.querySelectorAll(DRAG));
        let exclude;
        if (drag.length) {
          exclude = collect(document.querySelectorAll(":is(" + DRAG + ") :is(" + NO_DRAG + ")"));
        } else {
          const band = parseFloat(getComputedStyle(document.documentElement).getPropertyValue("--japp-titlebar-height")) || 0;
          drag = band > 0 ? [[0, 0, round(window.innerWidth), band]] : [];
          exclude = band > 0 ? collect(document.querySelectorAll(NO_DRAG), (r) => r[1] < band) : [];
        }
        const key = JSON.stringify([drag, exclude]);
        if (key === last) return;
        last = key;
        channel.postMessage(JSON.stringify({ module: "window", method: "setDragRegions", args: { drag, exclude } })).catch(() => {});
      };
      const schedule = () => {
        if (scheduled) return;
        scheduled = true;
        requestAnimationFrame(measure);
      };
      const start = () => {
        new MutationObserver(schedule).observe(document.documentElement, {
          subtree: true, childList: true, attributes: true,
          attributeFilter: ["data-japp-drag-region", "data-japp-no-drag", "class", "style", "hidden"],
        });
        new ResizeObserver(schedule).observe(document.documentElement);
        window.addEventListener("resize", schedule);
        document.addEventListener("scroll", schedule, true);
        document.addEventListener("transitionend", schedule, true);
        document.addEventListener("animationend", schedule, true);
        if (document.fonts) document.fonts.ready.then(schedule);
        schedule();
      };
      if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", start, { once: true });
      else start();
    })();
    """#

    // MARK: Context menu

    /// WebKit items that belong to a browser, not to an app.
    private static let browserItems = [
        "GoBack", "GoForward", "Reload", "OpenLink", "OpenFrame", "OpenImage", "OpenMedia",
        "DownloadLinkedFile", "DownloadImage", "DownloadMedia", "CopyLink", "CopyMediaLink", "CopyImage",
        "RevealImage", "CopySubject", "MediaStats",
    ]

    /// Removes browser items from a WebKit context menu, and Inspect Element
    /// unless `developer` is set, then tidies up separators.
    static func filter(_ menu: NSMenu, developer: Bool) {
        for item in menu.items {
            let identifier = item.identifier?.rawValue ?? ""
            guard identifier.hasPrefix("WKMenuItemIdentifier") else { continue }
            let name = identifier.dropFirst("WKMenuItemIdentifier".count)
            if browserItems.contains(where: { name.hasPrefix($0) }) || (!developer && name == "InspectElement") {
                menu.removeItem(item)
            }
        }
        var previousWasSeparator = true
        for item in menu.items {
            if item.isSeparatorItem && previousWasSeparator { menu.removeItem(item) } else { previousWasSeparator = item.isSeparatorItem }
        }
        if let last = menu.items.last, last.isSeparatorItem { menu.removeItem(last) }
    }
}
