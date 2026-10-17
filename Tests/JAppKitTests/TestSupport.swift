import Foundation
import XCTest
@testable import JAppKit

/// A fresh temporary directory, removed when the test finishes.
func makeTemporaryDirectory(_ test: XCTestCase) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("JAppKitTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    test.addTeardownBlock {
        // Restore permissions changed by tests before deleting.
        _ = try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        try? FileManager.default.removeItem(at: url)
    }
    return url.resolvingSymlinksInPath()
}

let minimalManifest = """
{
  "manifestVersion": 1,
  "id": "com.example.test",
  "name": "Test App",
  "version": "1.0.0",
  "entry": "index.html",
  "icon": "assets/icon.png",
  "window": { "width": 400, "height": 300 },
  "permissions": ["storage"]
}
"""

/// A 1×1 PNG, enough for icon handling.
let tinyPNG = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==")!

func writeFiles(_ files: [String: Data], to root: URL) throws {
    for (path, data) in files {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }
}

func sampleAppFiles(manifest: String = minimalManifest, html: String = "<!doctype html><title>t</title><link rel=stylesheet href=style.css><script src=app.js></script>") -> [String: Data] {
    [
        "manifest.json": Data(manifest.utf8),
        "index.html": Data(html.utf8),
        "style.css": Data("body { color: red; }".utf8),
        "app.js": Data("console.log('hi')".utf8),
        "assets/icon.png": tinyPNG,
    ]
}

func makeArchive(_ files: [(String, Data)]) throws -> Data {
    var writer = ZipWriter()
    for (path, data) in files { try writer.addFile(path: path, contents: data) }
    return try writer.finish()
}

func makeArchive(_ files: [String: Data]) throws -> Data {
    try makeArchive(files.sorted { $0.key < $1.key }.map { ($0.key, $0.value) })
}

@discardableResult
func runTool(_ executable: String, _ arguments: [String], in directory: URL? = nil) throws -> (status: Int32, output: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    if let directory { process.currentDirectoryURL = directory }
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    try process.run()
    let output = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (process.terminationStatus, String(decoding: output, as: UTF8.self))
}

extension Data {
    /// Offsets of every occurrence of a little-endian 32-bit signature.
    func offsets(ofSignature signature: UInt32) -> [Int] {
        guard count >= 4 else { return [] }
        return (0...(count - 4)).filter { u32($0) == signature }
    }

    mutating func write(u16 value: UInt16, at offset: Int) {
        self[offset] = UInt8(value & 0xFF)
        self[offset + 1] = UInt8(value >> 8)
    }

    mutating func write(u32 value: UInt32, at offset: Int) {
        for i in 0..<4 { self[offset + i] = UInt8((value >> (8 * UInt32(i))) & 0xFF) }
    }
}

let localSignature: UInt32 = 0x0403_4B50
let centralSignature: UInt32 = 0x0201_4B50
