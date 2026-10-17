import Foundation
import JAppKit
@preconcurrency import WebKit

/// Lets the task travel to the background queue and back; it is only touched on the main actor.
private struct TaskBox: @unchecked Sendable {
    let task: WKURLSchemeTask
}

/// Serves an app's files to its web view from the `.japp` archive in memory.
///
/// Every app is loaded from its own origin, `japp-resource://<app-id>/`, so
/// relative URLs, `fetch()`, ES modules and same-origin rules behave exactly as
/// they would on a web server, while nothing is extracted to disk. Requests for
/// any other host are refused.
@MainActor
final class ArchiveSchemeHandler: NSObject, WKURLSchemeHandler {
    nonisolated static let scheme = "japp-resource"

    private(set) var package: JAppPackage
    private var activeTasks: Set<ObjectIdentifier> = []
    private let queue = DispatchQueue(label: "dev.japp.runtime.resources", qos: .userInitiated)

    init(package: JAppPackage) {
        self.package = package
    }

    var host: String { package.manifest.normalizedID }
    var entryURL: URL { Self.url(host: host, path: package.manifest.entry) }

    static func url(host: String, path: String) -> URL {
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.path = "/" + path
        return components.url!
    }

    /// Swaps in a freshly loaded version of the app (after "Reload" or "Save & Run").
    func replacePackage(_ package: JAppPackage) {
        self.package = package
    }

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        let id = ObjectIdentifier(task)
        activeTasks.insert(id)
        let request = task.request
        guard let url = request.url, url.host?.lowercased() == host else {
            return finish(task, id: id, status: 403, body: Data("Forbidden".utf8), mime: "text/plain", headOnly: false)
        }
        let method = request.httpMethod?.uppercased() ?? "GET"
        guard method == "GET" || method == "HEAD" else {
            return finish(task, id: id, status: 405, body: Data("Method not allowed".utf8), mime: "text/plain", headOnly: false)
        }

        let rawPath = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath ?? url.path
        var path = String((rawPath.removingPercentEncoding ?? rawPath).drop(while: { $0 == "/" }))
        if path.isEmpty || path.hasSuffix("/") { path += "index.html" }

        let resources = package.resources
        let csp = Self.contentSecurityPolicy(allowNetwork: package.manifest.has(.network))
        let range = request.value(forHTTPHeaderField: "Range")
        let box = TaskBox(task: task)
        queue.async {
            let result = Result { try resources.data(at: path) }
            Task { @MainActor in
                let task = box.task
                switch result {
                case .success(let data?):
                    let mime = MIMEType.forPath(path)
                    var headers: [String: String] = [:]
                    if mime == "text/html" || mime == "application/xhtml+xml" {
                        headers["Content-Security-Policy"] = csp
                    }
                    if let range, let (body, contentRange) = Self.slice(data, range: range) {
                        headers["Content-Range"] = contentRange
                        self.finish(task, id: id, status: 206, body: body, mime: mime, headers: headers, headOnly: method == "HEAD")
                    } else {
                        self.finish(task, id: id, status: 200, body: data, mime: mime, headers: headers, headOnly: method == "HEAD")
                    }
                case .success(nil):
                    self.finish(task, id: id, status: 404, body: Data("Not found: \(path)".utf8), mime: "text/plain", headOnly: false)
                case .failure(let error):
                    self.finish(task, id: id, status: 500, body: Data("\(error)".utf8), mime: "text/plain", headOnly: false)
                }
            }
        }
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {
        // WebKit raises an exception if a stopped task is touched again.
        activeTasks.remove(ObjectIdentifier(task))
    }

    private func finish(_ task: WKURLSchemeTask, id: ObjectIdentifier, status: Int, body: Data, mime: String,
                        headers extra: [String: String] = [:], headOnly: Bool) {
        guard activeTasks.remove(id) != nil, let url = task.request.url else { return }
        var contentType = mime
        if MIMEType.isText(mime), String(data: body, encoding: .utf8) != nil { contentType += "; charset=utf-8" }
        var headers = extra
        headers["Content-Type"] = contentType
        headers["Content-Length"] = String(body.count)
        headers["Cache-Control"] = "no-store"
        headers["X-Content-Type-Options"] = "nosniff"
        headers["Accept-Ranges"] = "bytes"
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        task.didReceive(response)
        if !headOnly { task.didReceive(body) }
        task.didFinish()
    }

    /// Minimal single-range support (`bytes=a-b`, `bytes=a-`, `bytes=-n`), which media elements rely on.
    nonisolated static func slice(_ data: Data, range header: String) -> (Data, String)? {
        guard header.hasPrefix("bytes="), !data.isEmpty else { return nil }
        let spec = header.dropFirst(6)
        guard !spec.contains(","), let dash = spec.firstIndex(of: "-") else { return nil }
        let startText = spec[..<dash], endText = spec[spec.index(after: dash)...]
        let count = data.count
        var start: Int, end: Int
        if startText.isEmpty {
            guard let suffix = Int(endText), suffix > 0 else { return nil }
            start = max(0, count - suffix)
            end = count - 1
        } else {
            guard let s = Int(startText), s < count else { return nil }
            start = s
            end = endText.isEmpty ? count - 1 : min(Int(endText) ?? (count - 1), count - 1)
        }
        guard start <= end else { return nil }
        return (data.subdata(in: start..<(end + 1)), "bytes \(start)-\(end)/\(count)")
    }

    /// The policy sent with every HTML document. Inline scripts and `eval` stay
    /// allowed (plain-JS apps rely on them); what the policy enforces is that,
    /// without the `network` permission, nothing is loaded from outside the app.
    nonisolated static func contentSecurityPolicy(allowNetwork: Bool) -> String {
        let local = "'self' \(scheme): data: blob:"
        let remote = allowNetwork ? " https: http: wss: ws:" : ""
        return [
            "default-src \(local)\(remote)",
            "script-src \(local) 'unsafe-inline' 'unsafe-eval'\(remote)",
            "style-src \(local) 'unsafe-inline'\(remote)",
            "img-src \(local)\(remote)",
            "font-src \(local)\(remote)",
            "media-src \(local)\(remote)",
            "connect-src \(local)\(remote)",
            "frame-src \(local) about:\(remote)",
            "worker-src \(local)",
            "object-src 'none'",
            "base-uri 'self'",
            "form-action 'self'",
        ].joined(separator: "; ")
    }
}
