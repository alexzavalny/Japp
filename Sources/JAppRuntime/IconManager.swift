import AppKit
import JAppKit

/// Dock and Finder icons.
///
/// * Dock: one runtime process has one Dock tile, so the tile shows the icon of
///   the app it hosts (`NSApp.applicationIconImage`). With one process per app
///   (the default) every app gets its own tile; in single-process mode the tile
///   follows the frontmost app.
/// * Finder: see `FinderIcon` — re-applied whenever an app is opened or saved.
@MainActor
enum IconManager {
    static func image(for package: JAppPackage) -> NSImage? {
        package.iconData.flatMap { NSImage(data: $0) }
    }

    /// The generic `.japp` document icon (used when an app has no icon).
    static var genericIcon: NSImage {
        if let url = Bundle.main.url(forResource: "JAppDocument", withExtension: "icns"), let image = NSImage(contentsOf: url) {
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
        guard RuntimeSettings.setsFinderIcons || force else { return .noIcon }
        return FinderIcon.apply(for: package, force: force)
    }
}
