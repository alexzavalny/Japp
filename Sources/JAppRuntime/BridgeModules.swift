import AppKit
import JAppKit
import UniformTypeIdentifiers
import UserNotifications

// MARK: - japp.storage

/// Key-value storage in `~/Library/Application Support/JApp/Apps/<app-id>/storage.json`.
/// Values cross the bridge as JSON text so their types survive exactly.
struct StorageModule: BridgeModule {
    let name = "storage"

    func permission(for method: String) -> Permission? { .storage }

    func handle(_ method: String, args: [String: Any], session: AppSession) async throws -> Any? {
        let store = session.storage
        do {
            switch method {
            case "get": return try store.get(args.requiredString("key"))
            case "set": try store.set(args.requiredString("key"), json: args.requiredString("value", maxLength: .max))
            case "remove": try store.remove(args.requiredString("key"))
            case "clear": try store.clear()
            case "keys": return try store.keys()
            default: throw BridgeError(code: "NOT_SUPPORTED", message: "japp.storage.\(method) does not exist.")
            }
        } catch let error as StorageError {
            throw BridgeError(code: "STORAGE_ERROR", message: error.description)
        }
        return nil
    }
}

// MARK: - japp.dialog

/// File access always goes through a panel the user operates; the app only
/// ever receives the file the user picked (name and contents, never a path).
struct DialogModule: BridgeModule {
    let name = "dialog"
    static let maxFileSize = 32 * 1024 * 1024

    func permission(for method: String) -> Permission? {
        method == "message" ? nil : .dialog
    }

    func handle(_ method: String, args: [String: Any], session: AppSession) async throws -> Any? {
        switch method {
        case "openFile": return try await openFile(args, session: session)
        case "saveFile": return try await saveFile(args, session: session)
        case "message": return await message(args, session: session)
        default: throw BridgeError(code: "NOT_SUPPORTED", message: "japp.dialog.\(method) does not exist.")
        }
    }

    private func openFile(_ args: [String: Any], session: AppSession) async throws -> Any? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = args.bool("multiple") ?? false
        if let title = args.string("title") { panel.message = title }
        let types = Self.contentTypes(args["accept"])
        if !types.isEmpty { panel.allowedContentTypes = types }

        guard await session.runSheet(panel) == .OK else { return nil }
        let encoding = args.string("encoding") ?? "text"
        let files = try panel.urls.map { try Self.read($0, encoding: encoding) }
        return panel.allowsMultipleSelection ? files : files.first
    }

    private func saveFile(_ args: [String: Any], session: AppSession) async throws -> Any? {
        let content = try args.requiredString("content", maxLength: Self.maxFileSize * 2)
        let data: Data
        switch args.string("encoding") ?? "text" {
        case "text": data = Data(content.utf8)
        case "base64":
            guard let decoded = Data(base64Encoded: content) else { throw BridgeError.badArguments("“content” is not valid base64.") }
            data = decoded
        default: throw BridgeError.badArguments("“encoding” must be “text” or “base64”.")
        }

        let panel = NSSavePanel()
        panel.nameFieldStringValue = args.string("suggestedName") ?? "Untitled"
        if let title = args.string("title") { panel.message = title }
        let types = Self.contentTypes(args["accept"])
        if !types.isEmpty { panel.allowedContentTypes = types }
        guard await session.runSheet(panel) == .OK, let url = panel.url else { return nil }
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            throw BridgeError.failed("Could not save “\(url.lastPathComponent)”: \(error.localizedDescription)")
        }
        return ["name": url.lastPathComponent, "size": data.count]
    }

    private func message(_ args: [String: Any], session: AppSession) async -> Any? {
        let alert = NSAlert()
        alert.messageText = args.string("title") ?? session.manifest.name
        alert.informativeText = args.string("message") ?? ""
        alert.alertStyle = args.string("style") == "warning" ? .warning : (args.string("style") == "critical" ? .critical : .informational)
        alert.icon = session.icon
        let buttons = (args["buttons"] as? [String])?.prefix(4) ?? ["OK"]
        for title in buttons { alert.addButton(withTitle: title) }
        let response = await session.runAlert(alert)
        return response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
    }

    /// Accepts extensions (`"txt"`, `".json"`), MIME types (`"image/png"`) and wildcards (`"image/*"`).
    static func contentTypes(_ value: Any?) -> [UTType] {
        guard let list = value as? [String] else { return [] }
        return list.compactMap { item in
            let item = item.trimmingCharacters(in: .whitespaces)
            switch item {
            case "image/*": return .image
            case "audio/*": return .audio
            case "video/*": return .movie
            case "text/*": return .text
            default:
                if item.contains("/") { return UTType(mimeType: item) }
                return UTType(filenameExtension: item.hasPrefix(".") ? String(item.dropFirst()) : item)
            }
        }
    }

    static func read(_ url: URL, encoding: String) throws -> [String: Any] {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= maxFileSize else {
            throw BridgeError.failed("“\(url.lastPathComponent)” is larger than \(maxFileSize / 1024 / 1024) MB.")
        }
        let data = try Data(contentsOf: url)
        let mime = MIMEType.forPath(url.path)
        var file: [String: Any] = ["name": url.lastPathComponent, "size": data.count, "type": mime]
        switch encoding {
        case "text":
            guard let text = String(data: data, encoding: .utf8) else {
                throw BridgeError.failed("“\(url.lastPathComponent)” is not UTF-8 text; use { encoding: \"base64\" } or \"dataURL\".")
            }
            file["text"] = text
        case "base64": file["base64"] = data.base64EncodedString()
        case "dataURL": file["dataURL"] = "data:\(mime);base64," + data.base64EncodedString()
        default: throw BridgeError.badArguments("“encoding” must be “text”, “base64” or “dataURL”.")
        }
        return file
    }
}

// MARK: - japp.notification

struct NotificationModule: BridgeModule {
    let name = "notification"

    func permission(for method: String) -> Permission? { .notifications }

    func handle(_ method: String, args: [String: Any], session: AppSession) async throws -> Any? {
        guard method == "show" else { throw BridgeError(code: "NOT_SUPPORTED", message: "japp.notification.\(method) does not exist.") }
        guard Bundle.main.bundleIdentifier != nil else {
            throw BridgeError(code: "UNAVAILABLE", message: "Notifications require the runtime to run from JApp Runtime.app.")
        }
        let title = try args.requiredString("title", maxLength: 200)
        let center = UNUserNotificationCenter.current()
        let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        guard granted else {
            let sender = ProcessIdentity.appBundle?.name ?? "JApp Runtime"
            throw BridgeError(code: "NOT_AUTHORIZED",
                              message: "Notifications are turned off for \(sender). Enable them in System Settings › Notifications.")
        }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = args.string("body") ?? ""
        if let subtitle = args.string("subtitle") { content.subtitle = subtitle }
        if args.bool("sound") ?? true { content.sound = .default }
        content.threadIdentifier = session.manifest.normalizedID
        // An app bundle's notifications carry the app's name and icon. Run inside
        // JApp Runtime they are attributed to it, so name the app that sent them.
        if !ProcessIdentity.isAppBundle && content.subtitle.isEmpty { content.subtitle = session.manifest.name }
        try await center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        return nil
    }
}

// MARK: - japp.clipboard

struct ClipboardModule: BridgeModule {
    let name = "clipboard"

    func permission(for method: String) -> Permission? { .clipboard }

    func handle(_ method: String, args: [String: Any], session: AppSession) async throws -> Any? {
        let pasteboard = NSPasteboard.general
        switch method {
        case "readText":
            return pasteboard.string(forType: .string)
        case "writeText":
            let text = try args.requiredString("text", maxLength: 16 * 1024 * 1024)
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
            return nil
        default:
            throw BridgeError(code: "NOT_SUPPORTED", message: "japp.clipboard.\(method) does not exist.")
        }
    }
}

// MARK: - japp.window

/// Controls the app's own window only; needs no permission.
struct WindowModule: BridgeModule {
    let name = "window"

    func permission(for method: String) -> Permission? { nil }

    func handle(_ method: String, args: [String: Any], session: AppSession) async throws -> Any? {
        switch method {
        case "setTitle": session.window.title = try args.requiredString("title", maxLength: 200)
        case "setDocumentEdited":
            guard let edited = args["edited"] as? NSNumber, CFGetTypeID(edited) == CFBooleanGetTypeID() else {
                throw BridgeError.badArguments("“edited” must be true or false.")
            }
            session.window.isDocumentEdited = edited.boolValue
        case "close": session.close()
        case "minimize": session.window.miniaturize(nil)
        case "zoom": session.window.zoom(nil)
        case "setDragRegions":
            // Sent by the runtime's own page script (NativeFeel), not part of the public API.
            session.webView.setDragRegions(Self.rects(args["drag"]), excluding: Self.rects(args["exclude"]))
        default: throw BridgeError(code: "NOT_SUPPORTED", message: "japp.window.\(method) does not exist.")
        }
        return nil
    }

    /// `[[x, y, width, height], …]` in CSS pixels, at most 256.
    private static func rects(_ value: Any?) -> [NSRect] {
        guard let list = value as? [[NSNumber]] else { return [] }
        return list.prefix(256).compactMap { numbers in
            guard numbers.count == 4 else { return nil }
            let v = numbers.map { CGFloat($0.doubleValue) }
            guard v.allSatisfy({ $0.isFinite }), v[2] > 0, v[3] > 0 else { return nil }
            return NSRect(x: v[0], y: v[1], width: v[2], height: v[3])
        }
    }
}

// MARK: - japp.menu

/// Native context menus (`japp.menu.popup`): a real NSMenu at the pointer,
/// resolving to the chosen item's id. Needs no permission.
struct MenuModule: BridgeModule {
    let name = "menu"
    static let maxItems = 300
    static let maxDepth = 4

    func permission(for method: String) -> Permission? { nil }

    func handle(_ method: String, args: [String: Any], session: AppSession) async throws -> Any? {
        guard method == "popup" else { throw BridgeError(code: "NOT_SUPPORTED", message: "japp.menu.\(method) does not exist.") }
        guard let list = args["items"] as? [Any] else { throw BridgeError.badArguments("“items” must be an array.") }
        let picker = MenuPicker()
        var count = 0
        let menu = try Self.build(list, depth: 1, count: &count, picker: picker)
        guard menu.numberOfItems > 0 else { return nil }

        let webView = session.webView!
        let location: NSPoint
        if let x = (args["x"] as? NSNumber)?.doubleValue, let y = (args["y"] as? NSNumber)?.doubleValue, x.isFinite, y.isFinite {
            location = webView.viewPoint(fromPage: NSPoint(x: x, y: y))
        } else {
            location = webView.convert(session.window.mouseLocationOutsideOfEventStream, from: nil)
        }
        session.showWindow()
        if RuntimeSettings.isAutomating { Automation.menuWillPopUp(menu, at: webView.pagePoint(location)) }
        menu.popUp(positioning: nil, at: location, in: webView)
        // The chosen item's action may be delivered just after tracking ends.
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
        return picker.selected
    }

    /// "cmd+shift+z", "⌘⇧Z", "ctrl+pagedown" → an NSMenuItem key equivalent. Shown in the
    /// menu (and usable while it is open); the page still handles the keys itself.
    static func keyEquivalent(_ text: String) -> (String, NSEvent.ModifierFlags)? {
        var modifiers: NSEvent.ModifierFlags = []
        var rest = text.lowercased()
        for (symbol, flag) in [("⌘", NSEvent.ModifierFlags.command), ("⇧", .shift), ("⌥", .option), ("⌃", .control)] where rest.contains(symbol) {
            modifiers.insert(flag)
            rest = rest.replacingOccurrences(of: symbol, with: "+")
        }
        var key: String?
        for part in rest.split(separator: "+").map({ $0.trimmingCharacters(in: .whitespaces) }) where !part.isEmpty {
            switch part {
            case "cmd", "command": modifiers.insert(.command)
            case "shift": modifiers.insert(.shift)
            case "alt", "opt", "option": modifiers.insert(.option)
            case "ctrl", "control": modifiers.insert(.control)
            case "delete", "backspace": key = "\u{8}"
            case "del", "forwarddelete": key = String(UnicodeScalar(NSDeleteFunctionKey)!)
            case "esc", "escape": key = "\u{1b}"
            case "return", "enter": key = "\r"
            case "pageup": key = String(UnicodeScalar(NSPageUpFunctionKey)!)
            case "pagedown": key = String(UnicodeScalar(NSPageDownFunctionKey)!)
            default: key = part.count == 1 ? part : nil
            }
        }
        guard let key, key.count == 1 else { return nil }
        return (key, modifiers)
    }

    private static func build(_ list: [Any], depth: Int, count: inout Int, picker: MenuPicker) throws -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for entry in list {
            count += 1
            guard count <= maxItems else { throw BridgeError.badArguments("A menu may have at most \(maxItems) items.") }
            if let text = entry as? String, text == "-" {
                menu.addItem(.separator())
                continue
            }
            guard let spec = entry as? [String: Any] else {
                throw BridgeError.badArguments("Menu items must be objects such as { id: \"open\", label: \"Open\" }, or \"-\" for a separator.")
            }
            if spec.string("type") == "separator" {
                menu.addItem(.separator())
                continue
            }
            let label = try spec.requiredString("label", maxLength: 200)
            let item = NSMenuItem(title: label, action: nil, keyEquivalent: "")
            item.isEnabled = spec.bool("enabled") ?? true
            item.state = spec.bool("checked") == true ? .on : .off
            if let symbol = spec.string("symbol"), let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) {
                item.image = image
            }
            if let shortcut = spec.string("shortcut"), let (key, modifiers) = Self.keyEquivalent(shortcut) {
                item.keyEquivalent = key
                item.keyEquivalentModifierMask = modifiers
            }
            if let children = spec["submenu"] as? [Any] {
                guard depth < maxDepth else { throw BridgeError.badArguments("Menus may be nested at most \(maxDepth) levels deep.") }
                item.submenu = try build(children, depth: depth + 1, count: &count, picker: picker)
            } else {
                item.representedObject = spec.string("id") ?? label
                item.target = picker
                item.action = #selector(MenuPicker.pick(_:))
            }
            menu.addItem(item)
        }
        return menu
    }
}

/// Receives the chosen item of a `japp.menu.popup` menu.
@MainActor
final class MenuPicker: NSObject {
    private(set) var selected: String?

    @objc func pick(_ sender: NSMenuItem) {
        selected = sender.representedObject as? String
    }
}

// MARK: - japp.http

/// Native HTTP requests (`japp.http.fetch`), for talking to web APIs that do not
/// send CORS headers for an app's `japp-resource://` origin.
///
/// Requests run in an ephemeral session: no cookies, no cache and no stored
/// credentials are ever sent, so an app cannot ride on the user's web sessions.
/// Only http and https URLs are allowed, and only with the `network` permission.
struct HTTPModule: BridgeModule {
    let name = "http"
    static let maxResponseSize = 32 * 1024 * 1024
    private static let methods: Set<String> = ["GET", "HEAD", "POST", "PUT", "PATCH", "DELETE", "OPTIONS"]
    private static let forbiddenHeaders: Set<String> = ["host", "content-length", "connection", "cookie", "transfer-encoding"]

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCredentialStorage = nil
        return URLSession(configuration: configuration)
    }()

    func permission(for method: String) -> Permission? { .network }

    func handle(_ method: String, args: [String: Any], session appSession: AppSession) async throws -> Any? {
        guard method == "fetch" else { throw BridgeError(code: "NOT_SUPPORTED", message: "japp.http.\(method) does not exist.") }
        let address = try args.requiredString("url", maxLength: 8192)
        guard let url = URL(string: address), let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme), url.host != nil else {
            throw BridgeError.badArguments("“\(address)” is not an http or https URL.")
        }
        let httpMethod = (args.string("method") ?? "GET").uppercased()
        guard Self.methods.contains(httpMethod) else { throw BridgeError.badArguments("Unsupported HTTP method “\(httpMethod)”.") }

        var request = URLRequest(url: url)
        request.httpMethod = httpMethod
        request.timeoutInterval = min(max((args["timeout"] as? NSNumber)?.doubleValue ?? 30, 1), 120)
        request.setValue("JApp/\(JAppVersion.runtime) (\(appSession.manifest.id))", forHTTPHeaderField: "User-Agent")
        for (name, value) in args["headers"] as? [String: Any] ?? [:] {
            guard !Self.forbiddenHeaders.contains(name.lowercased()) else { continue }
            request.setValue("\(value)", forHTTPHeaderField: name)
        }
        if let body = args.string("body") {
            if args.string("bodyEncoding") == "base64" {
                guard let data = Data(base64Encoded: body) else { throw BridgeError.badArguments("“body” is not valid base64.") }
                request.httpBody = data
            } else {
                request.httpBody = Data(body.utf8)
            }
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await Self.session.data(for: request)
        } catch let error as URLError {
            throw BridgeError(code: "NETWORK_ERROR", message: error.localizedDescription)
        }
        guard data.count <= Self.maxResponseSize else {
            throw BridgeError(code: "NETWORK_ERROR", message: "The response is larger than \(Self.maxResponseSize / 1024 / 1024) MB.")
        }
        let http = response as? HTTPURLResponse
        var headers: [String: String] = [:]
        for (key, value) in http?.allHeaderFields ?? [:] { headers["\(key)".lowercased()] = "\(value)" }

        var result: [String: Any] = [
            "status": http?.statusCode ?? 0,
            "statusText": http.map { HTTPURLResponse.localizedString(forStatusCode: $0.statusCode) } ?? "",
            "url": response.url?.absoluteString ?? address,
            "headers": headers,
        ]
        if args.string("responseType") != "base64", let text = String(data: data, encoding: .utf8) {
            result["body"] = text
            result["bodyEncoding"] = "text"
        } else {
            result["body"] = data.base64EncodedString()
            result["bodyEncoding"] = "base64"
        }
        return result
    }
}
