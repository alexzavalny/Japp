import CryptoKit
import Foundation

public enum WorkspaceError: Error, CustomStringConvertible, LocalizedError {
    /// The `.japp` file changed on disk after the workspace was created.
    case archiveChangedOnDisk
    case invalidSource([ValidationIssue])
    case io(String)

    public var description: String {
        switch self {
        case .archiveChangedOnDisk:
            return "The .japp file was changed by another program after editing began."
        case .invalidSource(let issues):
            let errors = issues.filter { $0.severity == .error }
            return "The app cannot be saved until these problems are fixed:\n"
                + errors.map { "• " + ($0.field.map { "\($0): " } ?? "") + $0.message }.joined(separator: "\n")
        case .io(let detail):
            return detail
        }
    }

    public var errorDescription: String? { description }
}

/// An editable, unpacked copy of a `.japp` archive.
///
/// Layout (outside the archive, never inside it):
///
///     ~/Library/Application Support/JApp/Workspaces/<name>-<hash>/
///         session.json      which archive this is, and the state it was unpacked from
///         <App Name>/       the editable source folder opened in the code editor
///         backups/          the previous versions of the archive, newest last
///
/// The workspace survives quitting the runtime, so unsaved work is never lost;
/// it is deleted explicitly with `remove()` (the "Close" action in the runtime).
public final class SourceWorkspace {
    public struct Session: Codable, Equatable {
        public var archivePath: String
        /// SHA-256 of the archive the workspace was last synchronised with.
        public var archiveDigest: String
        /// SHA-256 of every source file at that point, keyed by relative path.
        public var baseFiles: [String: String]
        public var sourceFolderName: String
        public var createdAt: Date
        public var savedAt: Date?
    }

    public enum OpenOutcome: Equatable {
        case created
        case resumed
        /// An existing workspace was found but the archive changed since; the caller
        /// should offer to `discardChanges()` (re-extract) or keep the workspace.
        case resumedArchiveChanged
    }

    public struct Change: Equatable, CustomStringConvertible {
        public enum Kind: String { case added, modified, deleted }
        public let path: String
        public let kind: Kind
        public var description: String { "\(kind.rawValue): \(path)" }
    }

    public struct SaveResult {
        public let manifest: Manifest
        public let changes: [Change]
        public let warnings: [ValidationIssue]
        public let backup: URL?
    }

    public static let maxBackups = 5

    public let archiveURL: URL
    public let rootURL: URL
    public private(set) var session: Session

    public var sourceURL: URL { rootURL.appendingPathComponent(session.sourceFolderName, isDirectory: true) }
    public var backupsURL: URL { rootURL.appendingPathComponent("backups", isDirectory: true) }
    private var sessionURL: URL { rootURL.appendingPathComponent("session.json") }

    private var digestCache: [String: (stamp: Date, size: Int, digest: String)] = [:]

    private init(archiveURL: URL, rootURL: URL, session: Session) {
        self.archiveURL = archiveURL
        self.rootURL = rootURL
        self.session = session
    }

    /// The workspace directory used for a given archive path (one per archive location).
    public static func rootURL(for archiveURL: URL, in workspaces: URL = JAppPaths.workspacesDirectory) -> URL {
        let path = archiveURL.standardizedFileURL.path
        let hash = SHA256.hash(data: Data(path.utf8)).prefix(5).map { String(format: "%02x", $0) }.joined()
        let base = sanitize(archiveURL.deletingPathExtension().lastPathComponent)
        return workspaces.appendingPathComponent("\(base)-\(hash)", isDirectory: true)
    }

    /// The workspace for `archiveURL` if one exists (without creating it).
    public static func existing(for archiveURL: URL, workspaces: URL = JAppPaths.workspacesDirectory) -> SourceWorkspace? {
        let archiveURL = archiveURL.standardizedFileURL
        let root = rootURL(for: archiveURL, in: workspaces)
        guard let session = readSession(at: root), session.archivePath == archiveURL.path else { return nil }
        let workspace = SourceWorkspace(archiveURL: archiveURL, rootURL: root, session: session)
        return FileManager.default.fileExists(atPath: workspace.sourceURL.path) ? workspace : nil
    }

    /// Opens the workspace for `archiveURL`, unpacking the archive if no workspace exists yet.
    ///
    /// The archive only needs to be a readable ZIP: an app with a broken
    /// manifest can still be opened for editing, which is how it gets fixed.
    public static func open(archiveURL: URL, workspaces: URL = JAppPaths.workspacesDirectory) throws -> (SourceWorkspace, OpenOutcome) {
        let archiveURL = archiveURL.standardizedFileURL
        let root = rootURL(for: archiveURL, in: workspaces)
        let currentDigest = try sha256Hex(of: archiveURL)

        if let session = readSession(at: root), session.archivePath == archiveURL.path {
            let workspace = SourceWorkspace(archiveURL: archiveURL, rootURL: root, session: session)
            if FileManager.default.fileExists(atPath: workspace.sourceURL.path) {
                return (workspace, session.archiveDigest == currentDigest ? .resumed : .resumedArchiveChanged)
            }
        }

        try? FileManager.default.removeItem(at: root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let archive = try ZipArchive(url: archiveURL)
        let prefix = JAppPackage.rootPrefix(of: archive) ?? ""
        let folderName = sanitize(folderName(archive: archive, prefix: prefix, archiveURL: archiveURL))
        let session = Session(archivePath: archiveURL.path, archiveDigest: currentDigest, baseFiles: [:],
                              sourceFolderName: folderName, createdAt: Date(), savedAt: nil)
        let workspace = SourceWorkspace(archiveURL: archiveURL, rootURL: root, session: session)
        workspace.session.baseFiles = try Packager.extract(archive, rootPrefix: prefix, to: workspace.sourceURL)
        try workspace.writeSession()
        return (workspace, .created)
    }

    /// Whether the archive on disk still matches what the workspace was synchronised with.
    public func archiveChangedOnDisk() -> Bool {
        syncSession()
        return (try? sha256Hex(of: archiveURL)) != session.archiveDigest
    }

    /// Several tools may drive one workspace (the runtime's Edit Source window,
    /// `japp save`), so the session on disk is the source of truth.
    private func syncSession() {
        if let stored = Self.readSession(at: rootURL), stored.archivePath == session.archivePath { session = stored }
    }

    private static func readSession(at root: URL) -> Session? {
        guard let data = try? Data(contentsOf: root.appendingPathComponent("session.json")) else { return nil }
        return try? JSONDecoder.workspace.decode(Session.self, from: data)
    }

    /// Files added, modified or deleted in the workspace since it was unpacked or last saved.
    public func changes() throws -> [Change] {
        syncSession()
        let files = try Packager.collectFiles(in: sourceURL)
        var current: [String: String] = [:]
        for file in files {
            if let cached = digestCache[file.path], cached.stamp == file.modified, cached.size == file.size {
                current[file.path] = cached.digest
            } else {
                let digest = try sha256Hex(of: file.url)
                digestCache[file.path] = (file.modified, file.size, digest)
                current[file.path] = digest
            }
        }
        var changes: [Change] = []
        for (path, digest) in current {
            if let base = session.baseFiles[path] {
                if base != digest { changes.append(Change(path: path, kind: .modified)) }
            } else {
                changes.append(Change(path: path, kind: .added))
            }
        }
        for path in session.baseFiles.keys where current[path] == nil {
            changes.append(Change(path: path, kind: .deleted))
        }
        return changes.sorted { $0.path < $1.path }
    }

    /// Validates the workspace, repacks it and atomically replaces the `.japp` file.
    ///
    /// The original archive is never modified in place: the new archive is built
    /// and verified in memory, the old one is copied to `backups/`, and only then
    /// is it swapped in. If anything fails, the original file is left untouched.
    @discardableResult
    public func save(overwritingExternalChanges: Bool = false) throws -> SaveResult {
        syncSession()
        if !overwritingExternalChanges, FileManager.default.fileExists(atPath: archiveURL.path), archiveChangedOnDisk() {
            throw WorkspaceError.archiveChangedOnDisk
        }
        let report = PackageValidator.validate(url: sourceURL)
        guard report.isValid, let manifest = report.manifest else { throw WorkspaceError.invalidSource(report.issues) }

        let changes = try self.changes()
        let files = try Packager.collectFiles(in: sourceURL)
        let data = try Packager.archiveData(for: files)
        _ = try JAppPackage.load(archiveData: data, url: archiveURL)

        let backup = try backupCurrentArchive()
        do {
            try Packager.writeAtomically(data, to: archiveURL)
        } catch {
            throw WorkspaceError.io("Could not save “\(archiveURL.lastPathComponent)”: \(error.localizedDescription). The original file was not changed.")
        }

        var baseFiles: [String: String] = [:]
        for file in files { baseFiles[file.path] = try digestCache[file.path]?.digest ?? sha256Hex(of: file.url) }
        session.baseFiles = baseFiles
        session.archiveDigest = sha256Hex(data)
        session.savedAt = Date()
        try writeSession()
        return SaveResult(manifest: manifest, changes: changes, warnings: report.warnings, backup: backup)
    }

    /// Throws away workspace edits by unpacking the archive again.
    public func discardChanges() throws {
        let archive = try ZipArchive(url: archiveURL)
        let prefix = JAppPackage.rootPrefix(of: archive) ?? ""
        try? FileManager.default.removeItem(at: sourceURL)
        digestCache = [:]
        session.baseFiles = try Packager.extract(archive, rootPrefix: prefix, to: sourceURL)
        session.archiveDigest = try sha256Hex(of: archiveURL)
        try writeSession()
    }

    /// Deletes the workspace (source folder, session and backups).
    public func remove() throws {
        try FileManager.default.removeItem(at: rootURL)
    }

    private func backupCurrentArchive() throws -> URL? {
        guard FileManager.default.fileExists(atPath: archiveURL.path) else { return nil }
        let fm = FileManager.default
        try fm.createDirectory(at: backupsURL, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        let backup = backupsURL.appendingPathComponent("\(formatter.string(from: Date())).japp")
        try fm.copyItem(at: archiveURL, to: backup)

        let existing = (try? fm.contentsOfDirectory(at: backupsURL, includingPropertiesForKeys: nil)) ?? []
        let sorted = existing.filter { $0.pathExtension == "japp" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        for old in sorted.dropLast(Self.maxBackups) { try? fm.removeItem(at: old) }
        return backup
    }

    private func writeSession() throws {
        let data = try JSONEncoder.workspace.encode(session)
        try data.write(to: sessionURL, options: .atomic)
    }

    private static func folderName(archive: ZipArchive, prefix: String, archiveURL: URL) -> String {
        if let entry = archive.entry(at: prefix + Manifest.fileName),
           let data = try? archive.contents(of: entry),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let name = object["name"] as? String, !name.trimmingCharacters(in: .whitespaces).isEmpty {
            return name
        }
        return archiveURL.deletingPathExtension().lastPathComponent
    }

    static func sanitize(_ name: String) -> String {
        let cleaned = name.unicodeScalars.map { scalar -> Character in
            CharacterSet(charactersIn: "/:\\").contains(scalar) || CharacterSet.controlCharacters.contains(scalar) ? "-" : Character(scalar)
        }
        var result = String(cleaned).trimmingCharacters(in: .whitespaces)
        while result.hasPrefix(".") { result.removeFirst() }
        if result.count > 60 { result = String(result.prefix(60)) }
        return result.isEmpty ? "App" : result
    }
}

private extension JSONEncoder {
    static var workspace: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

private extension JSONDecoder {
    static var workspace: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
