import CryptoKit
import Foundation

public enum JAppError: Error, CustomStringConvertible, LocalizedError {
    case fileNotFound(URL)
    case archive(ArchiveError)
    case manifestMissing
    case invalidManifest([ValidationIssue])
    case entryMissing(String)
    case io(String)

    public var description: String {
        switch self {
        case .fileNotFound(let url): return "“\(url.path)” does not exist."
        case .archive(let error): return error.description
        case .manifestMissing:
            return "manifest.json was not found. It must be at the root of the archive (or inside a single top-level folder)."
        case .invalidManifest(let issues):
            let errors = issues.filter { $0.severity == .error }
            return "manifest.json is invalid:\n" + errors.map { "• " + ($0.field.map { "\($0): " } ?? "") + $0.message }.joined(separator: "\n")
        case .entryMissing(let entry): return "The entry file “\(entry)” named in manifest.json is not in the app."
        case .io(let detail): return detail
        }
    }

    public var errorDescription: String? { description }
}

/// Read access to an app's files, independent of where they live.
public protocol ResourceProvider: AnyObject, Sendable {
    /// Returns the contents of the file at the app-relative `path`, or nil if it does not exist.
    func data(at path: String) throws -> Data?
    /// All files in the app, as app-relative paths.
    var filePaths: [String] { get }
}

/// Serves files straight out of an in-memory ZIP archive (the normal case).
public final class ZipResourceProvider: ResourceProvider, @unchecked Sendable {
    public let archive: ZipArchive
    /// "" or "Folder/" when the archive wraps the app in a single top-level folder.
    public let rootPrefix: String
    private let exact: [String: ZipEntry]
    private let folded: [String: ZipEntry]

    init(archive: ZipArchive, rootPrefix: String) {
        self.archive = archive
        self.rootPrefix = rootPrefix
        var exact: [String: ZipEntry] = [:]
        var folded: [String: ZipEntry] = [:]
        for entry in archive.entries where !entry.isDirectory && entry.path.hasPrefix(rootPrefix) {
            let relative = String(entry.path.dropFirst(rootPrefix.count))
            exact[relative] = entry
            folded[ArchivePath.collisionKey(relative)] = entry
        }
        self.exact = exact
        self.folded = folded
    }

    public func data(at path: String) throws -> Data? {
        // Fall back to a case-insensitive match, mirroring how the app behaved
        // when its author tested it from a folder on APFS.
        guard let entry = exact[path] ?? folded[ArchivePath.collisionKey(path)] else { return nil }
        do {
            return try archive.contents(of: entry)
        } catch let error as ArchiveError {
            throw JAppError.archive(error)
        }
    }

    public var filePaths: [String] { exact.keys.sorted() }
}

/// Serves files from an unpacked app folder (developer mode: `japp run ./MyApp`).
public final class DirectoryResourceProvider: ResourceProvider, @unchecked Sendable {
    public let root: URL
    private let resolvedRoot: String
    private let limits: ArchiveLimits

    init(root: URL, limits: ArchiveLimits) {
        self.root = root.standardizedFileURL
        self.resolvedRoot = root.resolvingSymlinksInPath().standardizedFileURL.path
        self.limits = limits
    }

    public func data(at path: String) throws -> Data? {
        guard (try? ArchivePath.validate(path)) != nil else { return nil }
        let candidate = root.appendingPathComponent(path).resolvingSymlinksInPath().standardizedFileURL
        // Refuse anything that resolves outside the app folder (e.g. via a symlink).
        guard candidate.path.hasPrefix(resolvedRoot + "/") else { return nil }
        let values = try? candidate.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values?.isRegularFile == true else { return nil }
        if let size = values?.fileSize, size > limits.maxEntrySize {
            throw JAppError.io("“\(path)” is larger than \(limits.maxEntrySize) bytes")
        }
        return try Data(contentsOf: candidate)
    }

    public var filePaths: [String] {
        (try? Packager.collectFiles(in: root).map(\.path)) ?? []
    }
}

/// A loaded, validated JApp: its manifest plus access to its files.
public final class JAppPackage: @unchecked Sendable {
    public enum Kind: Sendable { case archive, directory }

    public let url: URL
    public let kind: Kind
    public let manifest: Manifest
    public let warnings: [ValidationIssue]
    public let resources: ResourceProvider
    /// SHA-256 of the archive bytes (archives only). Identifies one exact version of an app.
    public let archiveDigest: String?

    init(url: URL, kind: Kind, manifest: Manifest, warnings: [ValidationIssue], resources: ResourceProvider, archiveDigest: String?) {
        self.url = url
        self.kind = kind
        self.manifest = manifest
        self.warnings = warnings
        self.resources = resources
        self.archiveDigest = archiveDigest
    }

    /// Loads a `.japp` archive or an unpacked app folder and validates it.
    public static func load(from url: URL, limits: ArchiveLimits = .default) throws -> JAppPackage {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw JAppError.fileNotFound(url)
        }
        if isDirectory.boolValue {
            return try loadDirectory(url, limits: limits)
        }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        if size > limits.maxArchiveSize {
            throw JAppError.archive(.tooLarge("the file is \(size) bytes; the limit is \(limits.maxArchiveSize)"))
        }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw JAppError.io("Could not read “\(url.lastPathComponent)”: \(error.localizedDescription)")
        }
        return try load(archiveData: data, url: url, limits: limits)
    }

    public static func load(archiveData data: Data, url: URL, limits: ArchiveLimits = .default) throws -> JAppPackage {
        let archive: ZipArchive
        do {
            archive = try ZipArchive(data: data, limits: limits)
        } catch let error as ArchiveError {
            throw JAppError.archive(error)
        }
        guard let prefix = rootPrefix(of: archive) else { throw JAppError.manifestMissing }
        let provider = ZipResourceProvider(archive: archive, rootPrefix: prefix)
        return try finish(url: url, kind: .archive, provider: provider, digest: sha256Hex(data))
    }

    static func loadDirectory(_ url: URL, limits: ArchiveLimits) throws -> JAppPackage {
        let provider = DirectoryResourceProvider(root: url, limits: limits)
        return try finish(url: url.standardizedFileURL, kind: .directory, provider: provider, digest: nil)
    }

    private static func finish(url: URL, kind: Kind, provider: ResourceProvider, digest: String?) throws -> JAppPackage {
        guard let manifestData = try provider.data(at: Manifest.fileName) else { throw JAppError.manifestMissing }
        let result = Manifest.parse(manifestData)
        guard let manifest = result.manifest else { throw JAppError.invalidManifest(result.issues) }
        guard try provider.data(at: manifest.entry) != nil else { throw JAppError.entryMissing(manifest.entry) }

        var warnings = result.warnings
        if let icon = manifest.icon, try provider.data(at: icon) == nil {
            warnings.append(.warning("icon", "“\(icon)” is not in the app; the generic JApp icon will be used"))
        }
        return JAppPackage(url: url, kind: kind, manifest: manifest, warnings: warnings, resources: provider, archiveDigest: digest)
    }

    /// Where the app lives inside the archive: the root, or a single wrapping
    /// folder (what Finder's “Compress” produces when you compress a folder).
    public static func rootPrefix(of archive: ZipArchive) -> String? {
        if archive.entry(at: Manifest.fileName) != nil { return "" }
        let tops = Set(archive.entries.compactMap { $0.path.split(separator: "/").first.map(String.init) })
        guard tops.count == 1, let top = tops.first else { return nil }
        let prefix = top + "/"
        return archive.entry(at: prefix + Manifest.fileName) != nil ? prefix : nil
    }

    public var iconData: Data? {
        guard let icon = manifest.icon else { return nil }
        return try? resources.data(at: icon)
    }
}

public func sha256Hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

public func sha256Hex(of url: URL) throws -> String {
    sha256Hex(try Data(contentsOf: url))
}
