import CryptoKit
import Foundation
import JAppKit
@preconcurrency import WebKit

/// Builds the WebKit configuration for one app.
@MainActor
enum WebViewFactory {
    static func makeWebView(session: AppSession, schemeHandler: ArchiveSchemeHandler, bridge: NativeBridge,
                            console: ConsoleForwarder?) -> AppWebView {
        let configuration = WKWebViewConfiguration()

        // Each app id gets its own persistent WebKit data store, so localStorage,
        // IndexedDB, cookies and caches are isolated between apps.
        configuration.websiteDataStore = WKWebsiteDataStore(forIdentifier: dataStoreIdentifier(for: session.manifest.normalizedID))
        configuration.setURLSchemeHandler(schemeHandler, forURLScheme: ArchiveSchemeHandler.scheme)

        let controller = configuration.userContentController
        controller.addScriptMessageHandler(bridge, contentWorld: .page, name: NativeBridge.handlerName)
        if let console {
            controller.add(console, contentWorld: .page, name: ConsoleForwarder.handlerName)
        }

        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.preferences.isElementFullscreenEnabled = true
        // Desktop apps keep running (throttled) while in the background.
        configuration.preferences.inactiveSchedulingPolicy = .throttle
        // Adds Inspect Element to WebKit's context menus; AppWebView shows it only on
        // ⌥-right-click or in developer mode. (WebKit SPI; skipped if absent.)
        if configuration.preferences.responds(to: NSSelectorFromString("_setDeveloperExtrasEnabled:")) {
            configuration.preferences.setValue(true, forKey: "developerExtrasEnabled")
        }
        configuration.applicationNameForUserAgent = "JApp/\(JAppVersion.runtime)"

        let webView = AppWebView(frame: .zero, configuration: configuration)
        webView.allowsBackForwardNavigationGestures = false
        webView.allowsMagnification = false
        webView.allowsLinkPreview = false
        // Apps are documents meant to be inspected: ⌥-right-click › Inspect Element,
        // or Safari › Develop › <this Mac>.
        webView.isInspectable = true
        applyBackground(to: webView, session: session)
        return webView
    }

    /// Installs the bridge and native-feel scripts. Call again after a reload (the app info may have changed).
    static func installUserScripts(in controller: WKUserContentController, session: AppSession, console: Bool) {
        controller.removeAllUserScripts()
        if console {
            controller.addUserScript(WKUserScript(source: BridgeScript.consoleSource, injectionTime: .atDocumentStart,
                                                  forMainFrameOnly: true, in: .page))
        }
        controller.addUserScript(WKUserScript(source: BridgeScript.source(appInfo: session.appInfo), injectionTime: .atDocumentStart,
                                              forMainFrameOnly: true, in: .page))
        controller.addUserScript(WKUserScript(source: NativeFeel.script(state: session.nativeState), injectionTime: .atDocumentStart,
                                              forMainFrameOnly: true, in: .page))
    }

    /// With a window material the web view is transparent, so the material shows
    /// wherever the page has no background of its own.
    static func applyBackground(to webView: WKWebView, session: AppSession) {
        let transparent = session.manifest.window.material != nil
        // WebKit has no public switch for this; `drawsBackground` is WebKit SPI that hosts
        // use for transparent windows. Skipped (opaque web view) if a WebKit lacks it.
        if webView.responds(to: NSSelectorFromString("_setDrawsBackground:")) || webView.responds(to: NSSelectorFromString("setDrawsBackground:")) {
            webView.setValue(!transparent, forKey: "drawsBackground")
        }
        if transparent {
            webView.underPageBackgroundColor = .clear
        } else if let color = session.backgroundColor {
            webView.underPageBackgroundColor = color
        }
    }

    /// A stable UUID derived from the app id (name-based, SHA-256).
    static func dataStoreIdentifier(for appID: String) -> UUID {
        var bytes = Array(SHA256.hash(data: Data("dev.japp.website-data:\(appID)".utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50  // version 5-style
        bytes[8] = (bytes[8] & 0x3F) | 0x80  // RFC 4122 variant
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}
