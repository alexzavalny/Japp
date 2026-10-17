import AppKit
import JAppKit

/// First-launch confirmation for apps that came from the internet.
///
/// macOS marks downloaded files with the `com.apple.quarantine` attribute.
/// Gatekeeper never sees a `.japp` (it is a document, not code it knows how to
/// assess), so the runtime asks once, shows what the app requests, and offers to
/// inspect the source. Confirming removes the quarantine attribute, as
/// Gatekeeper does for apps.
@MainActor
enum TrustPolicy {
    private static let quarantineAttribute = "com.apple.quarantine"
    private static let trustedKey = "JAppTrustedArchives"

    static func isQuarantined(_ url: URL) -> Bool {
        getxattr(url.path, quarantineAttribute, nil, 0, 0, 0) > 0
    }

    static func allowsLaunch(of package: JAppPackage) -> Bool {
        guard package.kind == .archive, isQuarantined(package.url) else { return true }
        let digest = package.archiveDigest ?? ""
        var trusted = UserDefaults.standard.stringArray(forKey: trustedKey) ?? []
        if trusted.contains(digest) { return true }
        if RuntimeSettings.isAutomating {
            Automation.reportFailure(url: package.url, error: JAppError.io("The app is quarantined (downloaded from the internet) and needs confirmation."))
            return false
        }

        let manifest = package.manifest
        let requests = manifest.permissions.sorted { $0.rawValue < $1.rawValue }.map { "• " + $0.summary }
        let alert = NSAlert()
        alert.messageText = "“\(manifest.name)” was downloaded from the internet. Are you sure you want to open it?"
        alert.informativeText = """
            JApp apps run code on your Mac. Open “\(package.url.lastPathComponent)” (\(manifest.id)) only if you trust where it came from.

            \(requests.isEmpty ? "It requests no special permissions." : "It requests permission to:\n" + requests.joined(separator: "\n"))
            """
        alert.alertStyle = .warning
        alert.icon = IconManager.image(for: package)
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Open")
        alert.addButton(withTitle: "Show Source…")
        NSApp.activate()

        switch alert.runModal() {
        case .alertSecondButtonReturn:
            if removexattr(package.url.path, quarantineAttribute, 0) != 0 {
                trusted.append(digest)
                UserDefaults.standard.set(Array(trusted.suffix(500)), forKey: trustedKey)
            }
            return true
        case .alertThirdButtonReturn:
            ApplicationManager.shared.editSource(package.url)
            return false
        default:
            return false
        }
    }
}
