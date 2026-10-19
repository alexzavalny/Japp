import AppKit
import JAppKit

/// Dock and Finder icons.
///
/// * Dock: one process has one Dock tile. An app bundle's tile shows the app's icon
///   from the start (its Info.plist names it); the runtime also sets it at run time
///   (`NSApp.applicationIconImage`) so in-process hosting looks the same, and in
///   single-process mode the tile follows the frontmost app.
/// * Finder: see `FinderIcon` — re-applied whenever an app is opened or saved.
@MainActor
enum IconManager {
    static func image(for package: JAppPackage) -> NSImage? {
        package.iconData.flatMap { NSImage(data: $0) }
    }

    /// The generic `.japp` document icon (used when an app has no icon).
    static var genericIcon: NSImage {
        if let url = ProcessIdentity.runtimeResource("JAppDocument", "icns"), let image = NSImage(contentsOf: url) {
            return image
        }
        return NSApp.applicationIconImage
    }

    static func showInDock(_ image: NSImage?) {
        // nil restores the runtime's own icon.
        NSApp.applicationIconImage = image
    }

    @discardableResult
    static func applyFinderIcon(for package: JAppPackage, force: Bool = false) -> FinderIcon.Outcome {
        // A Finder icon is metadata written to the file; inside a signed app it would break the seal.
        guard RuntimeSettings.setsFinderIcons || force, !ProcessIdentity.isEmbedded(package.url) else { return .noIcon }
        return FinderIcon.apply(for: package, force: force)
    }
}
