import Foundation
import ImageIO

public struct ValidationReport: Sendable {
    public var issues: [ValidationIssue] = []
    public var manifest: Manifest?
    public var files: [String] = []

    public var errors: [ValidationIssue] { issues.filter { $0.severity == .error } }
    public var warnings: [ValidationIssue] { issues.filter { $0.severity == .warning } }
    public var isValid: Bool { errors.isEmpty }
}

/// Full validation of an app (archive or folder), shared by `japp validate`,
/// `japp pack`, source-workspace saving and the runtime.
public enum PackageValidator {
    public static func validate(url: URL, limits: ArchiveLimits = .default) -> ValidationReport {
        var report = ValidationReport()
        let package: JAppPackage
        do {
            package = try JAppPackage.load(from: url, limits: limits)
        } catch JAppError.invalidManifest(let issues) {
            report.issues = issues
            return report
        } catch {
            report.issues = [.error(nil, "\(error)")]
            return report
        }

        report.manifest = package.manifest
        report.files = package.resources.filePaths
        report.issues = package.warnings
        report.issues += iconIssues(package)
        report.issues += entryIssues(package)
        return report
    }

    private static func iconIssues(_ package: JAppPackage) -> [ValidationIssue] {
        guard let icon = package.manifest.icon else {
            return [.warning("icon", "no icon is set; the generic JApp icon will be used")]
        }
        guard let data = package.iconData, !icon.lowercased().hasSuffix(".svg") else { return [] }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else {
            return [.error("icon", "“\(icon)” is not a readable image")]
        }
        var issues: [ValidationIssue] = []
        if width != height { issues.append(.warning("icon", "“\(icon)” is \(width)×\(height); icons should be square")) }
        if max(width, height) < 256 {
            issues.append(.warning("icon", "“\(icon)” is only \(width)×\(height); use 1024×1024 for a sharp Dock and Finder icon"))
        }
        return issues
    }

    /// Lints the entry page for remote resources the app is not permitted to load.
    private static func entryIssues(_ package: JAppPackage) -> [ValidationIssue] {
        guard !package.manifest.has(.network),
              let data = try? package.resources.data(at: package.manifest.entry),
              let html = String(data: data, encoding: .utf8) else { return [] }
        let pattern = #"(?:src|href)\s*=\s*["']((?:https?:)?//[^"']+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        let matches = regex.matches(in: html, range: NSRange(html.startIndex..., in: html))
        return matches.prefix(5).compactMap { match in
            guard let range = Range(match.range(at: 1), in: html) else { return nil }
            return .warning(package.manifest.entry,
                            "loads “\(html[range])” but the app does not declare the “network” permission, so it will be blocked; bundle the file inside the app or add \"network\" to permissions")
        }
    }
}
