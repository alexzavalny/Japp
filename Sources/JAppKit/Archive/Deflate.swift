import Foundation
import zlib

/// Thin wrappers around the system zlib for raw DEFLATE (RFC 1951) streams,
/// which is what ZIP compression method 8 stores.
enum Deflate {
    private static let rawWindowBits: Int32 = -15

    /// Decompresses `input`, refusing to produce more than `expectedSize` bytes.
    /// The hard cap is what protects us against "zip bombs" that lie about their size.
    static func inflate(_ input: Data, expectedSize: Int) throws -> Data {
        var stream = z_stream()
        guard inflateInit2_(&stream, rawWindowBits, zlibVersion(), Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            throw ArchiveError.corrupt("could not initialise the DEFLATE decoder")
        }
        defer { inflateEnd(&stream) }

        // One spare byte lets us detect streams that expand beyond the declared size.
        var output = Data(count: expectedSize + 1)
        let status: Int32 = input.withUnsafeBytes { inBuf in
            output.withUnsafeMutableBytes { outBuf in
                // zlib never writes through next_in; the mutable cast only satisfies its C signature.
                stream.next_in = UnsafeMutablePointer(mutating: inBuf.bindMemory(to: Bytef.self).baseAddress)
                stream.avail_in = uInt(inBuf.count)
                stream.next_out = outBuf.bindMemory(to: Bytef.self).baseAddress
                stream.avail_out = uInt(outBuf.count)
                return zlib.inflate(&stream, Z_FINISH)
            }
        }
        guard status == Z_STREAM_END else {
            if status == Z_BUF_ERROR && stream.avail_out == 0 {
                throw ArchiveError.corrupt("compressed data expands beyond its declared size")
            }
            throw ArchiveError.corrupt("invalid DEFLATE data (zlib status \(status))")
        }
        guard Int(stream.total_out) == expectedSize else {
            throw ArchiveError.corrupt("decompressed size does not match the declared size")
        }
        output.count = expectedSize
        return output
    }

    static func deflate(_ input: Data) throws -> Data {
        var stream = z_stream()
        guard deflateInit2_(&stream, Z_BEST_COMPRESSION, Z_DEFLATED, rawWindowBits, 8, Z_DEFAULT_STRATEGY,
                            zlibVersion(), Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            throw ArchiveError.corrupt("could not initialise the DEFLATE encoder")
        }
        defer { deflateEnd(&stream) }

        let bound = Int(deflateBound(&stream, uLong(input.count)))
        var output = Data(count: max(bound, 16))
        let status: Int32 = input.withUnsafeBytes { inBuf in
            output.withUnsafeMutableBytes { outBuf in
                // zlib never writes through next_in; the mutable cast only satisfies its C signature.
                stream.next_in = UnsafeMutablePointer(mutating: inBuf.bindMemory(to: Bytef.self).baseAddress)
                stream.avail_in = uInt(inBuf.count)
                stream.next_out = outBuf.bindMemory(to: Bytef.self).baseAddress
                stream.avail_out = uInt(outBuf.count)
                return zlib.deflate(&stream, Z_FINISH)
            }
        }
        guard status == Z_STREAM_END else {
            throw ArchiveError.corrupt("DEFLATE compression failed (zlib status \(status))")
        }
        output.count = Int(stream.total_out)
        return output
    }
}

enum CRC32 {
    static func checksum(_ data: Data) -> UInt32 {
        data.withUnsafeBytes { buf -> UInt32 in
            guard let base = buf.bindMemory(to: Bytef.self).baseAddress else { return 0 }
            // zlib's crc32 takes a 32-bit length, so feed large buffers in chunks.
            var crc = zlib.crc32(0, nil, 0)
            var offset = 0
            while offset < buf.count {
                let chunk = min(buf.count - offset, Int(Int32.max))
                crc = zlib.crc32(crc, base + offset, uInt(chunk))
                offset += chunk
            }
            return UInt32(crc)
        }
    }
}
