import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Writes Apple icon (`.icns`) files: a header followed by PNG images of every
/// standard size. Made in-process, so generating an app bundle depends on no external tool.
public enum ICNS {
    /// Element types and their pixel sizes (16–512 pt at 1× and 2×).
    static let elements: [(type: String, pixels: Int)] = [
        ("icp4", 16), ("ic11", 32), ("icp5", 32), ("ic12", 64), ("ic07", 128), ("ic13", 256),
        ("ic08", 256), ("ic14", 512), ("ic09", 512), ("ic10", 1024),
    ]

    /// An `.icns` file from a PNG or JPEG image of any size (non-square images are
    /// centred); nil if the data is not an image.
    public static func make(fromImageData data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        var pngs: [Int: Data] = [:]
        var body = Data()
        for element in elements {
            if pngs[element.pixels] == nil { pngs[element.pixels] = png(of: image, size: element.pixels) }
            guard let png = pngs[element.pixels] else { return nil }
            body.append(contentsOf: Array(element.type.utf8))
            body.append(bigEndian: UInt32(png.count + 8))
            body.append(png)
        }
        var file = Data("icns".utf8)
        file.append(bigEndian: UInt32(body.count + 8))
        file.append(body)
        return file
    }

    /// The element types and PNG payloads of an `.icns` file (used by tests).
    public static func elements(of data: Data) -> [(type: String, png: Data)]? {
        guard data.count >= 8, data.prefix(4) == Data("icns".utf8), Int(data.bigEndianUInt32(at: 4)) == data.count else { return nil }
        var result: [(String, Data)] = []
        var offset = 8
        while offset + 8 <= data.count {
            let type = String(decoding: data[data.startIndex + offset ..< data.startIndex + offset + 4], as: UTF8.self)
            let length = Int(data.bigEndianUInt32(at: offset + 4))
            guard length >= 8, offset + length <= data.count else { return nil }
            result.append((type, data.subdata(in: data.startIndex + offset + 8 ..< data.startIndex + offset + length)))
            offset += length
        }
        return offset == data.count ? result : nil
    }

    private static func png(of image: CGImage, size: Int) -> Data? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        let scale = CGFloat(size) / CGFloat(max(image.width, image.height))
        let width = CGFloat(image.width) * scale, height = CGFloat(image.height) * scale
        context.draw(image, in: CGRect(x: (CGFloat(size) - width) / 2, y: (CGFloat(size) - height) / 2, width: width, height: height))
        guard let scaled = context.makeImage() else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, scaled, nil)
        return CGImageDestinationFinalize(destination) ? output as Data : nil
    }
}

private extension Data {
    mutating func append(bigEndian value: UInt32) {
        Swift.withUnsafeBytes(of: value.bigEndian) { append(contentsOf: $0) }
    }

    func bigEndianUInt32(at offset: Int) -> UInt32 {
        self[startIndex + offset ..< startIndex + offset + 4].reduce(0) { $0 << 8 | UInt32($1) }
    }
}
