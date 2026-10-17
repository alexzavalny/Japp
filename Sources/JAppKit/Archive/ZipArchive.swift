import Foundation

public struct ZipEntry: Sendable {
    /// The name exactly as stored in the archive (validated, `/`-separated).
    public let path: String
    public let isDirectory: Bool
    public let compressionMethod: UInt16
    public let crc32: UInt32
    public let compressedSize: Int
    public let uncompressedSize: Int
    public let modificationDate: Date?
    let dataOffset: Int
}

/// A read-only, fully validated, in-memory view of a ZIP archive.
///
/// Only the subset of ZIP needed for `.japp` files is supported: single-disk
/// archives, "stored" and "deflate" entries, no encryption, no ZIP64. Every
/// entry is validated up front (names, sizes, overlaps) so callers can trust
/// the `entries` list. Entry data is decompressed lazily and verified against
/// its CRC-32 on every read.
public final class ZipArchive: @unchecked Sendable {
    public let entries: [ZipEntry]
    private let data: Data
    private let index: [String: Int]

    private static let localHeaderSignature: UInt32 = 0x0403_4B50
    private static let centralHeaderSignature: UInt32 = 0x0201_4B50
    private static let endOfCentralDirectorySignature: UInt32 = 0x0605_4B50
    private static let zip64LocatorSignature: UInt32 = 0x0706_4B50

    public convenience init(url: URL, limits: ArchiveLimits = .default) throws {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true else { throw ArchiveError.notAZipArchive }
        if let size = values.fileSize, size > limits.maxArchiveSize {
            throw ArchiveError.tooLarge("the file is \(size) bytes; the limit is \(limits.maxArchiveSize)")
        }
        try self.init(data: Data(contentsOf: url), limits: limits)
    }

    public init(data input: Data, limits: ArchiveLimits = .default) throws {
        // Normalise to a zero-based buffer so offsets can be used directly.
        let data = input.startIndex == 0 ? input : Data(input)
        guard data.count <= limits.maxArchiveSize else {
            throw ArchiveError.tooLarge("the file is \(data.count) bytes; the limit is \(limits.maxArchiveSize)")
        }
        self.data = data

        let eocd = try Self.findEndOfCentralDirectory(in: data)
        if eocd >= 20, data.u32(eocd - 20) == Self.zip64LocatorSignature {
            throw ArchiveError.unsupported("ZIP64")
        }
        let diskNumber = data.u16(eocd + 4)
        let centralDirectoryDisk = data.u16(eocd + 6)
        let entriesOnDisk = Int(data.u16(eocd + 8))
        let entryCount = Int(data.u16(eocd + 10))
        let centralDirectorySize = Int(data.u32(eocd + 12))
        let centralDirectoryOffset = Int(data.u32(eocd + 16))

        if entryCount == 0xFFFF || centralDirectorySize == 0xFFFF_FFFF || centralDirectoryOffset == 0xFFFF_FFFF {
            throw ArchiveError.unsupported("ZIP64")
        }
        guard diskNumber == 0, centralDirectoryDisk == 0, entriesOnDisk == entryCount else {
            throw ArchiveError.unsupported("multi-volume archives")
        }
        guard entryCount <= limits.maxEntryCount else {
            throw ArchiveError.tooLarge("\(entryCount) entries; the limit is \(limits.maxEntryCount)")
        }
        let centralDirectoryEnd = centralDirectoryOffset + centralDirectorySize
        guard centralDirectoryEnd <= eocd else { throw ArchiveError.corrupt("central directory is out of bounds") }

        var entries: [ZipEntry] = []
        var index: [String: Int] = [:]
        var seen: Set<String> = []
        var occupied: [Range<Int>] = []
        var totalSize = 0
        var cursor = centralDirectoryOffset

        for _ in 0..<entryCount {
            guard cursor + 46 <= centralDirectoryEnd, data.u32(cursor) == Self.centralHeaderSignature else {
                throw ArchiveError.corrupt("invalid central directory record")
            }
            let versionMadeBy = data.u16(cursor + 4)
            let flags = data.u16(cursor + 8)
            let method = data.u16(cursor + 10)
            let dosTime = data.u16(cursor + 12)
            let dosDate = data.u16(cursor + 14)
            let crc = data.u32(cursor + 16)
            let compressedSize = Int(data.u32(cursor + 20))
            let uncompressedSize = Int(data.u32(cursor + 24))
            let nameLength = Int(data.u16(cursor + 28))
            let extraLength = Int(data.u16(cursor + 30))
            let commentLength = Int(data.u16(cursor + 32))
            let externalAttributes = data.u32(cursor + 38)
            let localHeaderOffset = Int(data.u32(cursor + 42))

            let nameRange = (cursor + 46)..<(cursor + 46 + nameLength)
            let recordEnd = nameRange.upperBound + extraLength + commentLength
            guard recordEnd <= centralDirectoryEnd else { throw ArchiveError.corrupt("central directory record overflows") }
            cursor = recordEnd

            let nameData = data.subdata(in: nameRange)
            guard let path = String(data: nameData, encoding: .utf8) else {
                throw ArchiveError.unsupported("file names that are not UTF-8")
            }
            if compressedSize == 0xFFFF_FFFF || uncompressedSize == 0xFFFF_FFFF || localHeaderOffset == 0xFFFF_FFFF {
                throw ArchiveError.unsupported("ZIP64")
            }
            if ArchivePath.isIgnored(path) { continue }

            try ArchivePath.validate(path, maxLength: limits.maxPathLength)
            if flags & 0x0001 != 0 || flags & 0x0040 != 0 {
                throw ArchiveError.unsupported("encrypted entries (“\(path)”)")
            }
            let isUnixHost = (versionMadeBy >> 8) == 3
            let unixMode = isUnixHost ? UInt16(truncatingIfNeeded: externalAttributes >> 16) : 0
            if unixMode & 0o170000 == 0o120000 { throw ArchiveError.symbolicLink(path) }

            let isDirectory = path.hasSuffix("/") || unixMode & 0o170000 == 0o040000
            guard seen.insert(ArchivePath.collisionKey(path)).inserted else { throw ArchiveError.duplicateEntry(path) }

            guard method == 0 || method == 8 else {
                throw ArchiveError.unsupported("compression method \(method) (“\(path)”); use Deflate or Store")
            }
            if method == 0 && compressedSize != uncompressedSize {
                throw ArchiveError.corrupt("stored entry “\(path)” has inconsistent sizes")
            }
            guard uncompressedSize <= limits.maxEntrySize else {
                throw ArchiveError.tooLarge("“\(path)” is \(uncompressedSize) bytes; the limit is \(limits.maxEntrySize)")
            }
            totalSize += uncompressedSize
            guard totalSize <= limits.maxTotalUncompressedSize else {
                throw ArchiveError.tooLarge("contents exceed \(limits.maxTotalUncompressedSize) bytes when uncompressed")
            }

            // The local header must agree with the central directory and lie before it.
            guard localHeaderOffset + 30 <= centralDirectoryOffset,
                  data.u32(localHeaderOffset) == Self.localHeaderSignature else {
                throw ArchiveError.corrupt("missing local header for “\(path)”")
            }
            let localNameLength = Int(data.u16(localHeaderOffset + 26))
            let localExtraLength = Int(data.u16(localHeaderOffset + 28))
            let localNameStart = localHeaderOffset + 30
            guard localNameStart + localNameLength <= centralDirectoryOffset,
                  data.subdata(in: localNameStart..<(localNameStart + localNameLength)) == nameData else {
                throw ArchiveError.corrupt("local header name does not match for “\(path)”")
            }
            let dataOffset = localNameStart + localNameLength + localExtraLength
            guard dataOffset + compressedSize <= centralDirectoryOffset else {
                throw ArchiveError.corrupt("data for “\(path)” is out of bounds")
            }
            occupied.append(localHeaderOffset..<(dataOffset + compressedSize))

            index[path] = entries.count
            entries.append(ZipEntry(
                path: path,
                isDirectory: isDirectory,
                compressionMethod: method,
                crc32: crc,
                compressedSize: compressedSize,
                uncompressedSize: uncompressedSize,
                modificationDate: DOSDate.date(time: dosTime, date: dosDate),
                dataOffset: dataOffset
            ))
        }

        // Overlapping entries are the signature of "non-recursive" zip bombs.
        occupied.sort { $0.lowerBound < $1.lowerBound }
        for (previous, next) in zip(occupied, occupied.dropFirst()) where previous.upperBound > next.lowerBound {
            throw ArchiveError.corrupt("entries overlap")
        }

        self.entries = entries
        self.index = index
    }

    public func entry(at path: String) -> ZipEntry? {
        index[path].map { entries[$0] }
    }

    /// Returns the decompressed, checksum-verified contents of `entry`.
    public func contents(of entry: ZipEntry) throws -> Data {
        if entry.isDirectory { return Data() }
        let raw = data.subdata(in: entry.dataOffset..<(entry.dataOffset + entry.compressedSize))
        let contents = entry.compressionMethod == 8
            ? try Deflate.inflate(raw, expectedSize: entry.uncompressedSize)
            : raw
        guard contents.count == entry.uncompressedSize, CRC32.checksum(contents) == entry.crc32 else {
            throw ArchiveError.checksumMismatch(entry.path)
        }
        return contents
    }

    private static func findEndOfCentralDirectory(in data: Data) throws -> Int {
        let minimumRecord = 22
        guard data.count >= minimumRecord else { throw ArchiveError.notAZipArchive }
        let lowest = max(0, data.count - minimumRecord - 0xFFFF)
        var offset = data.count - minimumRecord
        while offset >= lowest {
            if data.u32(offset) == endOfCentralDirectorySignature,
               offset + minimumRecord + Int(data.u16(offset + 20)) <= data.count {
                return offset
            }
            offset -= 1
        }
        throw ArchiveError.notAZipArchive
    }
}

enum DOSDate {
    static func components(from date: Date) -> (time: UInt16, date: UInt16) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let year = min(max(c.year ?? 1980, 1980), 2107)
        let time = UInt16((c.hour ?? 0) << 11 | (c.minute ?? 0) << 5 | (c.second ?? 0) / 2)
        let day = UInt16((year - 1980) << 9 | (c.month ?? 1) << 5 | (c.day ?? 1))
        return (time, day)
    }

    static func date(time: UInt16, date: UInt16) -> Date? {
        var c = DateComponents()
        c.year = Int(date >> 9) + 1980
        c.month = Int((date >> 5) & 0x0F)
        c.day = Int(date & 0x1F)
        c.hour = Int(time >> 11)
        c.minute = Int((time >> 5) & 0x3F)
        c.second = Int(time & 0x1F) * 2
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar.date(from: c)
    }
}

extension Data {
    // Callers bounds-check before reading; these assume a zero-based buffer.
    func u16(_ offset: Int) -> UInt16 {
        UInt16(self[offset]) | UInt16(self[offset + 1]) << 8
    }

    func u32(_ offset: Int) -> UInt32 {
        UInt32(self[offset]) | UInt32(self[offset + 1]) << 8 | UInt32(self[offset + 2]) << 16 | UInt32(self[offset + 3]) << 24
    }
}
