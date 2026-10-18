import Foundation
import JAppKit

/// JavaScript injected at document start into every app's main frame.
///
/// It defines `window.japp`, a frozen object whose methods return Promises.
/// Each call is serialised to JSON and posted to the native `japp` message
/// handler, which replies with a JSON envelope `{ok, value}` or `{ok, error}`.
/// The script holds no authority of its own: every permission check happens in Swift.
enum BridgeScript {
    static func source(appInfo: [String: Any]) -> String {
        let info = (try? JSONSerialization.data(withJSONObject: appInfo, options: [.sortedKeys]))
            .map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        return template
            .replacingOccurrences(of: "__JAPP_APP_INFO__", with: info)
            .replacingOccurrences(of: "__JAPP_RUNTIME_VERSION__", with: JAppVersion.runtime)
    }

    private static let template = #"""
    (() => {
      "use strict";
      if (window.japp) return;

      const channel = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.japp;
      const info = __JAPP_APP_INFO__;
      info.permissions = Object.freeze(info.permissions || []);
      const app = Object.freeze(info);

      class JAppError extends Error {
        constructor(code, message) {
          super(message);
          this.name = "JAppError";
          this.code = code;
        }
      }

      async function call(module, method, args) {
        if (!channel) {
          throw new JAppError("UNAVAILABLE", "The JApp native bridge is not available. Is this page running in JApp Runtime?");
        }
        const reply = await channel.postMessage(JSON.stringify({ module, method, args: args || {} }));
        const result = JSON.parse(reply);
        if (result.ok) return result.value;
        throw new JAppError(result.error.code, result.error.message);
      }

      function toJSON(value, what) {
        const json = value === undefined ? undefined : JSON.stringify(value);
        if (json === undefined) throw new TypeError(what + " must be a JSON-serializable value");
        return json;
      }

      const done = () => undefined;

      const storage = Object.freeze({
        async get(key, defaultValue = null) {
          const json = await call("storage", "get", { key: String(key) });
          return json === null ? defaultValue : JSON.parse(json);
        },
        async set(key, value) {
          await call("storage", "set", { key: String(key), value: toJSON(value, "japp.storage.set value") });
        },
        remove: (key) => call("storage", "remove", { key: String(key) }).then(done),
        clear: () => call("storage", "clear").then(done),
        keys: () => call("storage", "keys"),
      });

      const dialog = Object.freeze({
        openFile: (options = {}) => call("dialog", "openFile", options),
        saveFile: (options = {}) => call("dialog", "saveFile", options),
        message: (options = {}) => call("dialog", "message", typeof options === "string" ? { message: options } : options),
      });

      const notification = Object.freeze({
        show: (options = {}) => call("notification", "show", typeof options === "string" ? { title: options } : options).then(done),
      });

      const clipboard = Object.freeze({
        readText: () => call("clipboard", "readText"),
        writeText: (text) => call("clipboard", "writeText", { text: String(text) }).then(done),
      });

      /** A minimal Response-like object for japp.http.fetch results. */
      function makeResponse(raw) {
        const bytes = () => {
          if (raw.bodyEncoding === "base64") return Uint8Array.from(atob(raw.body), (c) => c.charCodeAt(0));
          return new TextEncoder().encode(raw.body);
        };
        const text = () => (raw.bodyEncoding === "base64" ? new TextDecoder().decode(bytes()) : raw.body);
        return Object.freeze({
          ok: raw.status >= 200 && raw.status < 300,
          status: raw.status,
          statusText: raw.statusText,
          url: raw.url,
          headers: Object.freeze(raw.headers),
          text: async () => text(),
          json: async () => JSON.parse(text()),
          arrayBuffer: async () => bytes().buffer,
        });
      }

      const http = Object.freeze({
        async fetch(url, options = {}) {
          let body = options.body;
          const headers = Object.assign({}, options.headers || {});
          if (body !== undefined && body !== null && typeof body !== "string") {
            body = JSON.stringify(body);
            if (!Object.keys(headers).some((name) => name.toLowerCase() === "content-type")) headers["Content-Type"] = "application/json";
          }
          const raw = await call("http", "fetch", {
            url: String(url), method: options.method || "GET", headers, body: body ?? undefined,
            timeout: options.timeout, responseType: options.responseType,
          });
          return makeResponse(raw);
        },
      });

      const menu = Object.freeze({
        popup: (items, options = {}) => call("menu", "popup", { items, x: options.x, y: options.y }),
      });

      const appWindow = Object.freeze({
        setTitle: (title) => call("window", "setTitle", { title: String(title) }).then(done),
        close: () => call("window", "close").then(done),
        minimize: () => call("window", "minimize").then(done),
        zoom: () => call("window", "zoom").then(done),
      });

      const japp = Object.freeze({
        runtimeVersion: "__JAPP_RUNTIME_VERSION__",
        app,
        hasPermission: (name) => app.permissions.includes(name),
        storage,
        dialog,
        notification,
        clipboard,
        http,
        menu,
        window: appWindow,
        JAppError,
      });

      Object.defineProperty(window, "japp", { value: japp, enumerable: true, configurable: false, writable: false });
    })();
    """#

    /// Forwards `console.*` output and uncaught errors to the runtime
    /// (`japp run --console`, `japp snapshot`). Only installed when requested.
    static let consoleSource = #"""
    (() => {
      "use strict";
      const channel = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.jappConsole;
      if (!channel) return;
      const describe = (value) => {
        if (typeof value === "string") return value;
        if (value instanceof Error) return value.stack ? value.message + "\n" + value.stack : String(value);
        try { return JSON.stringify(value); } catch (e) { return String(value); }
      };
      const send = (level, args) => {
        try { channel.postMessage({ level, message: Array.from(args, describe).join(" ") }); } catch (e) {}
      };
      for (const level of ["log", "info", "warn", "error", "debug"]) {
        const original = console[level].bind(console);
        console[level] = function (...args) { send(level, args); original(...args); };
      }
      window.addEventListener("error", (event) => {
        const target = event.target;
        if (target && target !== window && (target.src || target.href)) {
          // Resource errors (<script>, <link>, <img>) do not bubble; they arrive in the capture phase.
          send("error", ["Failed to load " + (target.src || target.href)]);
          return;
        }
        const where = event.filename ? " (" + event.filename + ":" + event.lineno + ":" + event.colno + ")" : "";
        send("error", ["Uncaught " + (event.error ? describe(event.error) : event.message) + where]);
      }, true);
      window.addEventListener("unhandledrejection", (event) => {
        send("error", ["Unhandled promise rejection: " + describe(event.reason)]);
      });
    })();
    """#
}
