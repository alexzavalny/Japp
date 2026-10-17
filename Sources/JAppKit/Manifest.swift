import Foundation

/// Native capabilities an app must declare in `manifest.json` before it may use them.
public enum Permission: String, CaseIterable, Sendable {
    /// `japp.storage.*` — persistent key-value storage.
    case storage
    /// `japp.dialog.openFile` / `saveFile` — user-mediated file access.
    case dialog
    /// `japp.notification.show` — system notifications.
    case notifications
    /// `japp.clipboard.*` — reading and writing the clipboard.
    case clipboard
    /// Loading remote resources (`fetch`, images, scripts, iframes over http/https/ws/wss).
    case network

    public var summary: String {
        switch self {
        case .storage: return "Store data on this Mac"
        case .dialog: return "Open and save files you choose"
        case .notifications: return "Show notifications"
        case .clipboard: return "Read and write the clipboard"
        case .network: return "Access the internet"
        }
    }
}

public struct ValidationIssue: Equatable, CustomStringConvertible, Sendable {
    public enum Severity: Sendable { case error, warning }

    public var severity: Severity
    /// The manifest field or file the issue refers to, e.g. `window.width`.
    public var field: String?
    public var message: String

    public static func error(_ field: String?, _ message: String) -> ValidationIssue {
        ValidationIssue(severity: .error, field: field, message: message)
    }

    public static func warning(_ field: String?, _ message: String) -> ValidationIssue {
        ValidationIssue(severity: .warning, field: field, message: message)
    }

    public var description: String {
        let prefix = severity == .error ? "error" : "warning"
        if let field { return "\(prefix): \(field): \(message)" }
        return "\(prefix): \(message)"
    }
}

public struct WindowOptions: Equatable, Sendable {
    public enum TitleBarStyle: String, Sendable {
        /// A standard macOS title bar.
        case `default`
        /// The title bar takes the window's `backgroundColor` and blends with the content.
        case transparent
        /// No title bar: the page fills the whole window and the traffic lights float over it.
        case hidden
        /// Like `hidden`, with the traffic lights inset as in apps that have a toolbar.
        case hiddenInset

        /// Whether the page extends under the title bar (and must leave room for the traffic lights).
        public var extendsUnderTitleBar: Bool { self == .hidden || self == .hiddenInset }
    }

    /// A system material (translucency) behind the page, seen wherever the page is transparent.
    public enum Material: String, Sendable, CaseIterable {
        case sidebar, window, underWindow, contentBackground, headerView, titlebar, menu, popover, hud, sheet
    }

    public var width: Double = 800
    public var height: Double = 600
    public var minWidth: Double?
    public var minHeight: Double?
    public var maxWidth: Double?
    public var maxHeight: Double?
    public var resizable = true
    public var titleBarStyle: TitleBarStyle = .default
    public var material: Material?
    /// `#RRGGBB`, `#RRGGBBAA` or `#RGB`; used before the page paints and behind a transparent title bar.
    public var backgroundColor: String?

    public init() {}
}

/// The parsed contents of `manifest.json`.
///
/// Parsing is deliberately tolerant of the future: unknown keys are ignored and
/// unknown permissions or enum values produce warnings, so apps written for a newer
/// runtime still open on an older one whenever that is safe. A `manifestVersion`
/// newer than the runtime understands is an error.
public struct Manifest: Equatable, Sendable {
    public static let supportedVersion = 1
    public static let fileName = "manifest.json"
    public static let maxSize = 1024 * 1024

    public var manifestVersion: Int
    public var id: String
    public var name: String
    public var version: String
    public var description: String?
    public var author: String?
    public var entry: String
    public var icon: String?
    public var window: WindowOptions
    public var permissions: Set<Permission>
    /// Permissions this runtime does not know about (ignored, reported as warnings).
    public var unknownPermissions: [String]

    /// Identifier used for storage directories, WebKit data stores and resource URLs.
    /// App identifiers are case-insensitive.
    public var normalizedID: String { id.lowercased() }

    public func has(_ permission: Permission) -> Bool { permissions.contains(permission) }

    // MARK: Parsing

    public struct ParseResult {
        public var manifest: Manifest?
        public var issues: [ValidationIssue]
        public var errors: [ValidationIssue] { issues.filter { $0.severity == .error } }
        public var warnings: [ValidationIssue] { issues.filter { $0.severity == .warning } }
    }

    public static func parse(_ data: Data) -> ParseResult {
        guard data.count <= maxSize else {
            return ParseResult(manifest: nil, issues: [.error(nil, "manifest.json is larger than \(maxSize / 1024) KB")])
        }
        let json: Any
        do {
            json = try JSONSerialization.jsonObject(with: data, options: [])
        } catch {
            let detail = (error as NSError).userInfo["NSDebugDescription"] as? String ?? error.localizedDescription
            return ParseResult(manifest: nil, issues: [.error(nil, "manifest.json is not valid JSON: \(detail)")])
        }
        guard let object = json as? [String: Any] else {
            return ParseResult(manifest: nil, issues: [.error(nil, "manifest.json must contain a JSON object")])
        }
        var parser = Parser(object: object)
        let manifest = parser.parse()
        let hasErrors = parser.issues.contains { $0.severity == .error }
        return ParseResult(manifest: hasErrors ? nil : manifest, issues: parser.issues)
    }

    /// `^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?` segments joined by dots, at least two segments.
    public static func isValidID(_ id: String) -> Bool {
        guard id.count <= 128 else { return false }
        let segments = id.split(separator: ".", omittingEmptySubsequences: false)
        guard segments.count >= 2 else { return false }
        return segments.allSatisfy { segment in
            guard let first = segment.first, let last = segment.last, segment.count <= 63 else { return false }
            let allowed = segment.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
            return allowed && first != "-" && last != "-"
        }
    }

    static func isValidVersion(_ version: String) -> Bool {
        version.range(of: #"^[0-9]+(\.[0-9]+){0,3}([-+][0-9A-Za-z.-]+)?$"#, options: .regularExpression) != nil
    }

    static func isValidColor(_ color: String) -> Bool {
        color.range(of: #"^#([0-9A-Fa-f]{3}|[0-9A-Fa-f]{6}|[0-9A-Fa-f]{8})$"#, options: .regularExpression) != nil
    }

    static let iconExtensions: Set<String> = ["png", "jpg", "jpeg", "icns", "gif", "tif", "tiff", "heic", "svg"]
    static let entryExtensions: Set<String> = ["html", "htm", "xhtml"]
}

private struct Parser {
    let object: [String: Any]
    var issues: [ValidationIssue] = []

    init(object: [String: Any]) { self.object = object }

    mutating func parse() -> Manifest {
        var manifestVersion = Manifest.supportedVersion
        if let raw = object["manifestVersion"] {
            if let value = integer(raw) {
                if value > Manifest.supportedVersion {
                    error("manifestVersion", "version \(value) requires a newer JApp Runtime (this runtime supports version \(Manifest.supportedVersion))")
                } else if value < 1 {
                    error("manifestVersion", "must be 1 or greater")
                }
                manifestVersion = value
            } else {
                error("manifestVersion", "must be an integer")
            }
        } else {
            error("manifestVersion", "is required (use 1)")
        }

        let id = requiredString("id") ?? ""
        if !id.isEmpty && !Manifest.isValidID(id) {
            error("id", "“\(id)” is not a valid identifier; use reverse-DNS form such as “com.example.calculator” (letters, digits and hyphens, separated by dots)")
        }

        let name = requiredString("name")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if name.count > 100 { error("name", "must be at most 100 characters") }
        if name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) {
            error("name", "must not contain control characters or line breaks")
        }

        let version = requiredString("version") ?? ""
        if !version.isEmpty && !Manifest.isValidVersion(version) {
            error("version", "“\(version)” is not a valid version; use a form such as “1.0.0”")
        }

        let description = optionalString("description")
        let author = optionalString("author")

        let entry = optionalString("entry") ?? "index.html"
        if validateRelativePath(entry, field: "entry") {
            let ext = (entry as NSString).pathExtension.lowercased()
            if !Manifest.entryExtensions.contains(ext) { error("entry", "must be an HTML file (.html or .htm)") }
        }

        let icon = optionalString("icon")
        if let icon, validateRelativePath(icon, field: "icon") {
            let ext = (icon as NSString).pathExtension.lowercased()
            if !Manifest.iconExtensions.contains(ext) {
                error("icon", "unsupported image type “.\(ext)”; use PNG (recommended, 1024×1024), JPEG or ICNS")
            } else if ext == "svg" {
                warning("icon", "SVG icons are not supported by every macOS version; prefer a 1024×1024 PNG")
            }
        }

        let window = parseWindow()

        var permissions = Set<Permission>()
        var unknownPermissions: [String] = []
        if let raw = object["permissions"] {
            if let list = raw as? [Any] {
                for (offset, item) in list.enumerated() {
                    guard let name = item as? String else {
                        error("permissions[\(offset)]", "must be a string")
                        continue
                    }
                    if let permission = Permission(rawValue: name) {
                        permissions.insert(permission)
                    } else {
                        unknownPermissions.append(name)
                        let known = Permission.allCases.map(\.rawValue).joined(separator: ", ")
                        warning("permissions", "unknown permission “\(name)” is ignored by this runtime (known: \(known))")
                    }
                }
            } else {
                error("permissions", "must be an array of strings")
            }
        }

        return Manifest(
            manifestVersion: manifestVersion, id: id, name: name, version: version,
            description: description, author: author, entry: entry, icon: icon,
            window: window, permissions: permissions, unknownPermissions: unknownPermissions
        )
    }

    private mutating func parseWindow() -> WindowOptions {
        var window = WindowOptions()
        guard let raw = object["window"] else { return window }
        guard let dict = raw as? [String: Any] else {
            error("window", "must be an object")
            return window
        }

        func dimension(_ key: String) -> Double? {
            guard let raw = dict[key] else { return nil }
            guard let value = number(raw) else {
                error("window.\(key)", "must be a number")
                return nil
            }
            guard (100...16_384).contains(value) else {
                error("window.\(key)", "must be between 100 and 16384 (got \(formatted(value)))")
                return nil
            }
            return value
        }

        if let width = dimension("width") { window.width = width }
        if let height = dimension("height") { window.height = height }
        window.minWidth = dimension("minWidth")
        window.minHeight = dimension("minHeight")
        window.maxWidth = dimension("maxWidth")
        window.maxHeight = dimension("maxHeight")

        if let min = window.minWidth, min > window.width { error("window.minWidth", "must not be larger than window.width") }
        if let min = window.minHeight, min > window.height { error("window.minHeight", "must not be larger than window.height") }
        if let max = window.maxWidth, max < window.width { error("window.maxWidth", "must not be smaller than window.width") }
        if let max = window.maxHeight, max < window.height { error("window.maxHeight", "must not be smaller than window.height") }

        if let raw = dict["resizable"] {
            if let flag = boolean(raw) { window.resizable = flag } else { error("window.resizable", "must be true or false") }
        }
        if let raw = dict["titleBarStyle"] {
            if let style = raw as? String {
                if let parsed = WindowOptions.TitleBarStyle(rawValue: style) {
                    window.titleBarStyle = parsed
                } else {
                    warning("window.titleBarStyle", "unknown style “\(style)”; using “default” (known: default, transparent, hidden, hiddenInset)")
                }
            } else {
                error("window.titleBarStyle", "must be a string")
            }
        }
        if let raw = dict["material"] {
            if let name = raw as? String {
                if let material = WindowOptions.Material(rawValue: name) {
                    window.material = material
                } else {
                    let known = WindowOptions.Material.allCases.map(\.rawValue).joined(separator: ", ")
                    warning("window.material", "unknown material “\(name)”; ignored (known: \(known))")
                }
            } else {
                error("window.material", "must be a string")
            }
        }
        if let raw = dict["backgroundColor"] {
            if let color = raw as? String, Manifest.isValidColor(color) {
                window.backgroundColor = color
            } else {
                error("window.backgroundColor", "must be a hex color such as “#1C1C1E”")
            }
        }
        return window
    }

    // MARK: Helpers

    private mutating func requiredString(_ key: String) -> String? {
        guard let raw = object[key] else {
            error(key, "is required")
            return nil
        }
        guard let value = raw as? String, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            error(key, "must be a non-empty string")
            return nil
        }
        return value
    }

    private mutating func optionalString(_ key: String) -> String? {
        guard let raw = object[key], !(raw is NSNull) else { return nil }
        guard let value = raw as? String else {
            error(key, "must be a string")
            return nil
        }
        return value
    }

    private mutating func validateRelativePath(_ path: String, field: String) -> Bool {
        do {
            try ArchivePath.validate(path)
            if path.hasSuffix("/") { error(field, "must name a file, not a folder"); return false }
            return true
        } catch {
            self.error(field, "“\(path)” must be a relative path inside the app (for example “assets/icon.png”)")
            return false
        }
    }

    private func isBoolean(_ value: Any) -> Bool {
        guard let number = value as? NSNumber else { return false }
        return CFGetTypeID(number) == CFBooleanGetTypeID()
    }

    private func number(_ value: Any) -> Double? {
        guard !isBoolean(value), let number = value as? NSNumber else { return nil }
        return number.doubleValue
    }

    private func integer(_ value: Any) -> Int? {
        guard let double = number(value), double.rounded() == double, abs(double) < 1e9 else { return nil }
        return Int(double)
    }

    private func boolean(_ value: Any) -> Bool? {
        isBoolean(value) ? (value as? NSNumber)?.boolValue : nil
    }

    private func formatted(_ value: Double) -> String {
        value.rounded() == value ? String(Int(value)) : String(value)
    }

    private mutating func error(_ field: String, _ message: String) { issues.append(.error(field, message)) }
    private mutating func warning(_ field: String, _ message: String) { issues.append(.warning(field, message)) }
}
