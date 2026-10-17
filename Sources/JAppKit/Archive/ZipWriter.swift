import Foundation

/// Builds a standard ZIP archive in memory.
///
/// The output is deliberately conventional (UTF-8 names, Unix permissions,
/// Deflate or Store) so that `unzip`, Archive Utility, Python's `zipfile`
/// and every other ZIP tool can read it.
///
/// The writer does not validate names: packaging code validates its inputs,
/// and tests use the writer to build deliberately malicious archives.
struct ZipWriter {
    enum Compression { case automatic, store, deflate }

    private var output = Data()
    private var centralDirectory = Data()
    private var entryCount = 0

    /// File types that are already compressed; deflating them only wastes time.
    private static let precompressedExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "webp", "heic", "avif", "ico", "icns",
        "woff", "woff2", "zip", "gz", "bz2", "xz", "japp",
        "mp3", "m4a", "aac", "ogg", "opus", "mp4", "m4v", "mov", "webm",
    ]

    mutating func addFile(
        path: String,
        contents: Data,
        modified: Date = Date(),
        permissions: UInt16 = 0o644,
        compression: Compression = .automatic,
        externalAttributes: UInt32? = nil,
        flags: UInt16 = 0x0800  // bit 11: names are UTF-8
    ) throws {
        let nameData = Data(path.utf8)
        guard nameData.count <= 0xFFFF else { throw ArchiveError.unsafePath(path, reason: "name too long") }

        let ext = (path as NSString).pathExtension.lowercased()
        var method: UInt16 = 0
        var payload = contents
        if compression == .deflate || (compression == .automatic && !Self.precompressedExtensions.contains(ext) && !contents.isEmpty) {
            let deflated = try Deflate.deflate(contents)
            if compression == .deflate || deflated.count < contents.count {
                method = 8
                payload = deflated
            }
        }

        let localOffset = output.count
        guard localOffset + 30 + nameData.count + payload.count < 0xFFFF_FFFF, contents.count < 0xFFFF_FFFF else {
            throw ArchiveError.tooLarge("archives larger than 4 GB are not supported")
        }
        let crc = CRC32.checksum(contents)
        let (dosTime, dosDate) = DOSDate.components(from: modified)

        var local = Data()
        local.append(u32: 0x0403_4B50)
        local.append(u16: 20)                 // version needed to extract (2.0)
        local.append(u16: flags)
        local.append(u16: method)
        local.append(u16: dosTime)
        local.append(u16: dosDate)
        local.append(u32: crc)
        local.append(u32: UInt32(payload.count))
        local.append(u32: UInt32(contents.count))
        local.append(u16: UInt16(nameData.count))
        local.append(u16: 0)                  // extra field length
        local.append(nameData)
        output.append(local)
        output.append(payload)

        var central = Data()
        central.append(u32: 0x0201_4B50)
        central.append(u16: 3 << 8 | 20)      // made by: Unix, spec 2.0
        central.append(u16: 20)
        central.append(u16: flags)
        central.append(u16: method)
        central.append(u16: dosTime)
        central.append(u16: dosDate)
        central.append(u32: crc)
        central.append(u32: UInt32(payload.count))
        central.append(u32: UInt32(contents.count))
        central.append(u16: UInt16(nameData.count))
        central.append(u16: 0)                // extra field length
        central.append(u16: 0)                // comment length
        central.append(u16: 0)                // disk number start
        central.append(u16: 0)                // internal attributes
        central.append(u32: externalAttributes ?? (UInt32(0o100000 | permissions) << 16))
        central.append(u32: UInt32(localOffset))
        central.append(nameData)
        centralDirectory.append(central)
        entryCount += 1
    }

    func finish() throws -> Data {
        guard entryCount < 0xFFFF else { throw ArchiveError.tooLarge("more than 65,534 entries") }
        var result = output
        let centralOffset = result.count
        result.append(centralDirectory)
        result.append(u32: 0x0605_4B50)
        result.append(u16: 0)                 // this disk
        result.append(u16: 0)                 // disk with central directory
        result.append(u16: UInt16(entryCount))
        result.append(u16: UInt16(entryCount))
        result.append(u32: UInt32(centralDirectory.count))
        result.append(u32: UInt32(centralOffset))
        result.append(u16: 0)                 // comment length
        return result
    }
}

private extension Data {
    mutating func append(u16 value: UInt16) {
        append(contentsOf: [UInt8(value & 0xFF), UInt8(value >> 8)])
    }

    mutating func append(u32 value: UInt32) {
        append(contentsOf: [UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF), UInt8((value >> 16) & 0xFF), UInt8(value >> 24)])
    }
}
