import Foundation

public struct PackFile: Sendable {
    /// App-relative, `/`-separated path.
    public let path: String
    public let url: URL
    public let size: Int
    public let modified: Date
}

/// Turns an app folder into a `.japp` archive (and back).
public enum Packager {
    /// Names that never go into an archive: hidden files (`.git`, `.DS_Store`,
    /// `.vscode`, …), Finder artefacts and editor backup files.
    public static func isExcluded(_ name: String) -> Bool {
        name.hasPrefix(".") || name == "__MACOSX" || name == "Thumbs.db" || name.hasSuffix("~")
    }

    public static func collectFiles(in root: URL, excluding excluded: Set<String> = [], limits: ArchiveLimits = .default) throws -> [PackFile] {
        let root = root.standardizedFileURL
        guard let enumerator = FileManager.default.enumerator(atPath: root.path) else {
            throw JAppError.io("Could not read the folder “\(root.path)”.")
        }
        let excludedPaths = Set(excluded.map { URL(fileURLWithPath: $0).standardizedFileURL.path })
        var files: [PackFile] = []
        var total = 0

        while let relative = enumerator.nextObject() as? String {
            let attributes = enumerator.fileAttributes ?? [:]
            let type = attributes[.type] as? FileAttributeType
            let name = (relative as NSString).lastPathComponent
            if isExcluded(name) {
                if type == .typeDirectory { enumerator.skipDescendants() }
                continue
            }
            if type == .typeSymbolicLink {
                throw JAppError.io("“\(relative)” is a symbolic link. Symbolic links are not supported in apps; copy the file instead.")
            }
            guard type == .typeRegular else { continue }

            let url = root.appendingPathComponent(relative)
            if excludedPaths.contains(url.standardizedFileURL.path) { continue }
            do {
                try ArchivePath.validate(relative, maxLength: limits.maxPathLength)
            } catch {
                throw JAppError.io("Cannot include “\(relative)”: \(error)")
            }
            let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
            guard size <= limits.maxEntrySize else {
                throw JAppError.io("“\(relative)” is \(size) bytes; files may be at most \(limits.maxEntrySize) bytes.")
            }
            total += size
            guard total <= limits.maxTotalUncompressedSize else {
                throw JAppError.io("The app's files exceed \(limits.maxTotalUncompressedSize) bytes in total.")
            }
            files.append(PackFile(path: relative, url: url, size: size,
                                  modified: attributes[.modificationDate] as? Date ?? Date()))
        }
        guard files.count <= limits.maxEntryCount else {
            throw JAppError.io("The app has \(files.count) files; the limit is \(limits.maxEntryCount).")
        }
        return files.sorted { $0.path < $1.path }
    }

    /// Builds archive bytes for the given files. Entries are sorted, so packing
    /// the same folder twice yields the same entry order.
    public static func archiveData(for files: [PackFile]) throws -> Data {
        var writer = ZipWriter()
        for file in files {
            let contents = try Data(contentsOf: file.url)
            try writer.addFile(path: file.path, contents: contents, modified: file.modified)
        }
        return try writer.finish()
    }

    public struct PackResult: Sendable {
        public let output: URL
        public let manifest: Manifest
        public let fileCount: Int
        public let archiveSize: Int
        public let warnings: [ValidationIssue]
    }

    /// Validates `directory` and writes it to `output` as a `.japp` archive.
    /// An existing file at `output` is replaced atomically, and only after the
    /// new archive has been built and verified.
    @discardableResult
    public static func pack(directory: URL, to output: URL, limits: ArchiveLimits = .default) throws -> PackResult {
        let report = PackageValidator.validate(url: directory, limits: limits)
        guard report.isValid, let manifest = report.manifest else {
            throw JAppError.invalidManifest(report.issues)
        }
        let files = try collectFiles(in: directory, excluding: [output.path], limits: limits)
        let data = try archiveData(for: files)
        // Verify the archive we are about to write loads exactly like the folder did.
        _ = try JAppPackage.load(archiveData: data, url: output, limits: limits)
        try writeAtomically(data, to: output)
        return PackResult(output: output, manifest: manifest, fileCount: files.count,
                          archiveSize: data.count, warnings: report.issues.filter { $0.severity == .warning })
    }

    /// Writes `data` to `url` so that readers see either the old file or the new
    /// one, never a partial write. On failure the original file is untouched.
    public static func writeAtomically(_ data: Data, to url: URL) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else {
            try data.write(to: url, options: .atomic)
            return
        }
        do {
            // Same-volume temporary directory, then an atomic swap that keeps
            // the original's creation date, permissions and Finder tags.
            let staging = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: url, create: true)
            defer { try? fm.removeItem(at: staging) }
            let temporary = staging.appendingPathComponent(url.lastPathComponent)
            try data.write(to: temporary)
            _ = try fm.replaceItemAt(url, withItemAt: temporary, backupItemName: nil, options: [])
        } catch {
            // Some volumes (FAT, network shares) have no replacement directory;
            // fall back to Foundation's write-to-temp-and-rename.
            try data.write(to: url, options: .atomic)
        }
    }

    /// Extracts every file of `archive` (below `rootPrefix`) into `destination`.
    /// Paths were validated when the archive was opened; each destination is
    /// still checked to lie inside `destination` as defence in depth.
    @discardableResult
    public static func extract(_ archive: ZipArchive, rootPrefix: String, to destination: URL) throws -> [String: String] {
        let fm = FileManager.default
        let root = destination.standardizedFileURL
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let rootPath = root.resolvingSymlinksInPath().path + "/"
        var digests: [String: String] = [:]

        for entry in archive.entries where !entry.isDirectory && entry.path.hasPrefix(rootPrefix) {
            let relative = String(entry.path.dropFirst(rootPrefix.count))
            guard !relative.isEmpty else { continue }
            let target = root.appendingPathComponent(relative).standardizedFileURL
            let parent = target.deletingLastPathComponent()
            try fm.createDirectory(at: parent, withIntermediateDirectories: true)
            guard parent.resolvingSymlinksInPath().path.appending("/").hasPrefix(rootPath) else {
                throw ArchiveError.unsafePath(entry.path, reason: "resolves outside the destination folder")
            }
            let contents = try archive.contents(of: entry)
            guard fm.createFile(atPath: target.path, contents: contents) else {
                throw JAppError.io("Could not write “\(relative)”.")
            }
            if let date = entry.modificationDate {
                try? fm.setAttributes([.modificationDate: date], ofItemAtPath: target.path)
            }
            digests[relative] = sha256Hex(contents)
        }
        return digests
    }
}
