import Foundation

/// Hard limits applied whenever an archive is read or written. They keep a
/// hostile `.japp` from exhausting memory or disk ("zip bombs").
public struct ArchiveLimits: Sendable {
    public var maxArchiveSize: Int = 256 * 1024 * 1024
    public var maxEntryCount: Int = 10_000
    public var maxEntrySize: Int = 256 * 1024 * 1024
    public var maxTotalUncompressedSize: Int = 1024 * 1024 * 1024
    public var maxPathLength: Int = 1024

    public init() {}
    public static let `default` = ArchiveLimits()
}

public enum ArchiveError: Error, Equatable, CustomStringConvertible, LocalizedError {
    case notAZipArchive
    case corrupt(String)
    case unsupported(String)
    case unsafePath(String, reason: String)
    case symbolicLink(String)
    case duplicateEntry(String)
    case tooLarge(String)
    case checksumMismatch(String)

    public var description: String {
        switch self {
        case .notAZipArchive: return "The file is not a ZIP archive."
        case .corrupt(let detail): return "The archive is damaged: \(detail)."
        case .unsupported(let detail): return "The archive uses an unsupported feature: \(detail)."
        case .unsafePath(let path, let reason): return "Unsafe file name “\(path)” in archive: \(reason)."
        case .symbolicLink(let path): return "The archive contains a symbolic link (“\(path)”), which is not allowed."
        case .duplicateEntry(let path): return "The archive contains “\(path)” more than once."
        case .tooLarge(let detail): return "The archive is too large: \(detail)."
        case .checksumMismatch(let path): return "“\(path)” failed its checksum; the archive is damaged."
        }
    }

    public var errorDescription: String? { description }
}

/// Rules for the file names stored inside a `.japp` archive.
///
/// Names are relative, `/`-separated, UTF-8 paths. Anything that could escape the
/// archive root when extracted ("ZIP Slip") is rejected rather than "fixed".
public enum ArchivePath {
    /// Finder/Archive Utility artefacts that are silently skipped when reading.
    public static func isIgnored(_ path: String) -> Bool {
        let components = path.split(separator: "/", omittingEmptySubsequences: true)
        if components.contains("__MACOSX") { return true }
        guard let last = components.last else { return false }
        return last == ".DS_Store" || last.hasPrefix("._")
    }

    public static func validate(_ path: String, maxLength: Int = ArchiveLimits.default.maxPathLength) throws {
        func fail(_ reason: String) -> ArchiveError { .unsafePath(path, reason: reason) }

        if path.isEmpty { throw fail("empty name") }
        if path.utf8.count > maxLength { throw fail("name is longer than \(maxLength) bytes") }
        if path.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) {
            throw fail("contains control characters")
        }
        if path.contains("\\") { throw fail("backslashes are not allowed; use “/” as the separator") }
        if path.hasPrefix("/") { throw fail("absolute paths are not allowed") }
        if path.count >= 2, path.dropFirst().first == ":", path.first?.isLetter == true {
            throw fail("drive letters are not allowed")
        }

        var components = path.split(separator: "/", omittingEmptySubsequences: false)
        if path.hasSuffix("/") { components.removeLast() }  // directory entry
        for component in components {
            if component.isEmpty { throw fail("contains an empty path component") }
            if component == "." || component == ".." { throw fail("“\(component)” path components are not allowed") }
            if component.utf8.count > 255 { throw fail("a path component is longer than 255 bytes") }
        }
    }

    /// Key used to detect entries that would collide on a case-insensitive,
    /// normalisation-insensitive file system such as APFS.
    public static func collisionKey(_ path: String) -> String {
        var trimmed = path
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        return trimmed.precomposedStringWithCanonicalMapping.lowercased()
    }
}
