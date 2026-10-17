import AppKit

/// Custom Finder icons for `.japp` files.
///
/// A custom icon is file-system metadata (a resource fork plus a Finder-info
/// flag) written by `NSWorkspace.setIcon`. It does not survive email, web
/// downloads or most cloud storage, so the runtime re-applies it whenever an app
/// is opened or saved. The icon inside the archive always stays the source of truth.
public enum FinderIcon {
    /// Records which icon was applied, so unchanged icons are not rewritten on every launch.
    private static let markerAttribute = "dev.japp.icon-digest"
    private static let resourceForkAttribute = "com.apple.ResourceFork"

    public enum Outcome: Equatable {
        case applied, alreadyCurrent, removed, noIcon, failed
    }

    /// Gives the archive at `package.url` the icon stored inside it.
    @discardableResult
    public static func apply(for package: JAppPackage, force: Bool = false) -> Outcome {
        guard package.kind == .archive else { return .noIcon }
        let path = package.url.path
        guard let data = package.iconData, let image = NSImage(data: data), image.isValid else {
            // The app no longer has an icon: drop a custom icon set earlier.
            if attribute(markerAttribute, of: path) != nil {
                remove(from: package.url)
                return .removed
            }
            return .noIcon
        }
        let digest = sha256Hex(data)
        if !force, attribute(markerAttribute, of: path) == digest, attribute(resourceForkAttribute, of: path) != nil {
            return .alreadyCurrent
        }
        guard NSWorkspace.shared.setIcon(image, forFile: path, options: []) else { return .failed }
        let bytes = Array(digest.utf8)
        setxattr(path, markerAttribute, bytes, bytes.count, 0, 0)
        return .applied
    }

    public static func remove(from url: URL) {
        NSWorkspace.shared.setIcon(nil, forFile: url.path, options: [])
        removexattr(url.path, markerAttribute, 0)
    }

    public static func hasCustomIcon(_ url: URL) -> Bool {
        attribute(resourceForkAttribute, of: url.path) != nil
    }

    private static func attribute(_ name: String, of path: String) -> String? {
        let size = getxattr(path, name, nil, 0, 0, 0)
        guard size > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard getxattr(path, name, &buffer, size, 0, 0) == size else { return nil }
        return String(decoding: buffer, as: UTF8.self)
    }
}
