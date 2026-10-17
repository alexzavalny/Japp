import AppKit
import JAppKit
@preconcurrency import WebKit

/// An error returned to JavaScript as a rejected Promise carrying a `JAppError` with `code`.
struct BridgeError: Error {
    let code: String
    let message: String

    static func badArguments(_ message: String) -> BridgeError { BridgeError(code: "BAD_ARGUMENTS", message: message) }
    static func failed(_ message: String) -> BridgeError { BridgeError(code: "FAILED", message: message) }
}

/// One namespace of the JavaScript API (`japp.storage`, `japp.dialog`, …).
@MainActor
protocol BridgeModule {
    var name: String { get }
    /// The manifest permission required to call `method`, or nil if none is needed.
    func permission(for method: String) -> Permission?
    /// Returns a JSON-serialisable value (or nil for `null`).
    func handle(_ method: String, args: [String: Any], session: AppSession) async throws -> Any?
}

/// Routes messages from `window.japp` to native modules, enforcing that
///
/// * messages come from the app's own main frame and origin,
/// * the module and method exist, and
/// * the app declared the permission the method requires.
@MainActor
final class NativeBridge: NSObject, WKScriptMessageHandlerWithReply {
    static let handlerName = "japp"
    static let maxMessageSize = 48 * 1024 * 1024

    private weak var session: AppSession?
    private let modules: [String: BridgeModule]

    init(session: AppSession) {
        self.session = session
        let all: [BridgeModule] = [StorageModule(), DialogModule(), NotificationModule(), ClipboardModule(), WindowModule(), HTTPModule(),
                                  MenuModule()]
        self.modules = Dictionary(uniqueKeysWithValues: all.map { ($0.name, $0) })
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage,
                               replyHandler: @escaping (Any?, String?) -> Void) {
        let reply: (Result<Any?, BridgeError>) -> Void = { result in replyHandler(Self.envelope(result), nil) }
        guard let session else { return reply(.failure(BridgeError(code: "UNAVAILABLE", message: "The app is closing."))) }

        let origin = message.frameInfo.securityOrigin
        guard message.frameInfo.isMainFrame, origin.protocol == ArchiveSchemeHandler.scheme,
              origin.host.lowercased() == session.manifest.normalizedID else {
            return reply(.failure(BridgeError(code: "FORBIDDEN", message: "Only the app's own top-level page may use the JApp API.")))
        }
        guard let body = message.body as? String, body.utf8.count <= Self.maxMessageSize,
              let request = try? JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any],
              let moduleName = request["module"] as? String, let method = request["method"] as? String else {
            return reply(.failure(.badArguments("Malformed bridge request.")))
        }
        guard let module = modules[moduleName] else {
            return reply(.failure(BridgeError(code: "NOT_SUPPORTED", message: "japp.\(moduleName) is not available in this runtime.")))
        }
        if let permission = module.permission(for: method), !session.manifest.has(permission) {
            return reply(.failure(BridgeError(
                code: "PERMISSION_DENIED",
                message: "japp.\(moduleName).\(method) requires the “\(permission.rawValue)” permission. Add \"\(permission.rawValue)\" to \"permissions\" in manifest.json.")))
        }
        let args = request["args"] as? [String: Any] ?? [:]
        Task { @MainActor in
            do {
                reply(.success(try await module.handle(method, args: args, session: session)))
            } catch let error as BridgeError {
                reply(.failure(error))
            } catch {
                reply(.failure(.failed("\(error)")))
            }
        }
    }

    private static func envelope(_ result: Result<Any?, BridgeError>) -> String {
        let object: [String: Any]
        switch result {
        case .success(let value): object = ["ok": true, "value": value ?? NSNull()]
        case .failure(let error): object = ["ok": false, "error": ["code": error.code, "message": error.message]]
        }
        if let data = try? JSONSerialization.data(withJSONObject: object, options: [.fragmentsAllowed]) {
            return String(decoding: data, as: UTF8.self)
        }
        return #"{"ok":false,"error":{"code":"FAILED","message":"The native result could not be encoded."}}"#
    }
}

/// Receives forwarded `console.*` messages (see `BridgeScript.consoleSource`).
@MainActor
final class ConsoleForwarder: NSObject, WKScriptMessageHandler {
    static let handlerName = "jappConsole"
    private weak var session: AppSession?

    init(session: AppSession) { self.session = session }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any],
              let level = body["level"] as? String, let text = body["message"] as? String else { return }
        session?.recordConsole(level: level, message: text)
    }
}

// MARK: - Argument helpers

extension Dictionary where Key == String, Value == Any {
    func string(_ key: String) -> String? { self[key] as? String }

    func requiredString(_ key: String, maxLength: Int = 10_000) throws -> String {
        guard let value = self[key] as? String else { throw BridgeError.badArguments("“\(key)” must be a string.") }
        guard value.count <= maxLength else { throw BridgeError.badArguments("“\(key)” is longer than \(maxLength) characters.") }
        return value
    }

    func bool(_ key: String) -> Bool? { (self[key] as? NSNumber).map(\.boolValue) }
}
