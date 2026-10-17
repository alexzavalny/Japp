import Foundation

public enum StorageError: Error, CustomStringConvertible, LocalizedError {
    case invalidKey(String)
    case invalidValue(String)
    case quotaExceeded(String)
    case io(String)

    public var description: String {
        switch self {
        case .invalidKey(let detail), .invalidValue(let detail), .quotaExceeded(let detail), .io(let detail):
            return detail
        }
    }

    public var errorDescription: String? { description }
}

/// Persistent key-value storage for one app, backed by a human-readable JSON file:
///
///     ~/Library/Application Support/JApp/Apps/<app-id>/storage.json
///
/// Values are arbitrary JSON. Every mutation takes an exclusive `flock` and
/// re-reads the file if another process changed it, so two windows (or two
/// runtime processes) of the same app never overwrite each other's keys.
public final class KeyValueStore: @unchecked Sendable {
    public static let maxKeyLength = 512
    public static let maxValueSize = 5 * 1024 * 1024
    public static let maxTotalSize = 50 * 1024 * 1024

    public let directory: URL
    public var fileURL: URL { directory.appendingPathComponent("storage.json") }
    private var lockURL: URL { directory.appendingPathComponent(".storage.lock") }

    private let mutex = NSLock()
    private var items: [String: Any] = [:]
    private var loadedStamp: FileStamp?

    private struct FileStamp: Equatable {
        let modified: Date
        let size: Int
    }

    public init(directory: URL) {
        self.directory = directory
    }

    public convenience init(appID: String) {
        self.init(directory: JAppPaths.dataDirectory(forAppID: appID))
    }

    // MARK: Public API (values are JSON text)

    /// Returns the stored value as JSON text, or nil when the key is absent.
    public func get(_ key: String) throws -> String? {
        try validate(key: key)
        return try locked {
            try refreshIfChanged()
            guard let value = items[key] else { return nil }
            return try Self.serialize(value)
        }
    }

    /// Stores `json` (any JSON value, e.g. `"text"`, `42`, `{"a":[1,2]}`) under `key`.
    public func set(_ key: String, json: String) throws {
        try validate(key: key)
        guard json.utf8.count <= Self.maxValueSize else {
            throw StorageError.quotaExceeded("The value for “\(key)” is larger than \(Self.maxValueSize / 1024 / 1024) MB.")
        }
        let value: Any
        do {
            value = try JSONSerialization.jsonObject(with: Data(json.utf8), options: [.fragmentsAllowed])
        } catch {
            throw StorageError.invalidValue("The value for “\(key)” is not valid JSON.")
        }
        try mutate { $0[key] = value }
    }

    public func remove(_ key: String) throws {
        try validate(key: key)
        try mutate { $0.removeValue(forKey: key) }
    }

    public func clear() throws {
        try mutate { $0.removeAll() }
    }

    public func keys() throws -> [String] {
        try locked {
            try refreshIfChanged()
            return items.keys.sorted()
        }
    }

    // MARK: Internals

    private func validate(key: String) throws {
        guard !key.isEmpty, key.count <= Self.maxKeyLength else {
            throw StorageError.invalidKey("Storage keys must be non-empty strings of at most \(Self.maxKeyLength) characters.")
        }
    }

    private func locked<T>(_ body: () throws -> T) throws -> T {
        mutex.lock()
        defer { mutex.unlock() }
        return try body()
    }

    private func mutate(_ change: (inout [String: Any]) throws -> Void) throws {
        try locked {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let fd = open(lockURL.path, O_CREAT | O_RDWR, 0o600)
            guard fd >= 0 else { throw StorageError.io("Could not open the storage lock file.") }
            defer { close(fd) }
            guard flock(fd, LOCK_EX) == 0 else { throw StorageError.io("Could not lock app storage.") }
            defer { flock(fd, LOCK_UN) }

            try refreshIfChanged()
            var updated = items
            try change(&updated)
            let data = try Self.encodeFile(updated)
            guard data.count <= Self.maxTotalSize else {
                throw StorageError.quotaExceeded("App storage is limited to \(Self.maxTotalSize / 1024 / 1024) MB.")
            }
            do {
                try data.write(to: fileURL, options: .atomic)
            } catch {
                throw StorageError.io("Could not save app storage: \(error.localizedDescription)")
            }
            items = updated
            loadedStamp = stamp()
        }
    }

    private func stamp() -> FileStamp? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
              let modified = attributes[.modificationDate] as? Date,
              let size = attributes[.size] as? NSNumber else { return nil }
        return FileStamp(modified: modified, size: size.intValue)
    }

    private func refreshIfChanged() throws {
        let current = stamp()
        guard current != loadedStamp || current == nil else { return }
        guard current != nil else {
            items = [:]
            loadedStamp = nil
            return
        }
        do {
            let data = try Data(contentsOf: fileURL)
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            items = object?["items"] as? [String: Any] ?? [:]
            loadedStamp = current
        } catch {
            throw StorageError.io("App storage at “\(fileURL.path)” is unreadable: \(error.localizedDescription)")
        }
    }

    private static func encodeFile(_ items: [String: Any]) throws -> Data {
        let file: [String: Any] = ["format": "japp-storage", "version": 1, "items": items]
        return try JSONSerialization.data(withJSONObject: file, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    private static func serialize(_ value: Any) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self)
    }
}
