import Foundation
import XCTest
@testable import JAppKit

final class ZipArchiveTests: XCTestCase {
    func testCRC32KnownValues() {
        XCTAssertEqual(CRC32.checksum(Data("hello".utf8)), 0x3610_A686)
        XCTAssertEqual(CRC32.checksum(Data("123456789".utf8)), 0xCBF4_3926)
        XCTAssertEqual(CRC32.checksum(Data()), 0)
    }

    func testRoundTripPreservesContents() throws {
        let text = Data(String(repeating: "JApp is a document. ", count: 500).utf8)
        let binary = Data((0..<4096).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        let files: [(String, Data)] = [
            ("index.html", text),
            ("assets/icon.png", tinyPNG),
            ("assets/data.bin", binary),
            ("empty.txt", Data()),
            ("ünïcødé/файл.txt", Data("unicode".utf8)),
        ]
        let archive = try ZipArchive(data: try makeArchive(files))
        XCTAssertEqual(archive.entries.map(\.path), files.map(\.0))
        for (path, data) in files {
            let entry = try XCTUnwrap(archive.entry(at: path))
            XCTAssertEqual(try archive.contents(of: entry), data, path)
        }
        XCTAssertEqual(archive.entry(at: "index.html")?.compressionMethod, 8, "text should be deflated")
        XCTAssertEqual(archive.entry(at: "assets/icon.png")?.compressionMethod, 0, "PNG should be stored")
    }

    func testOutputIsReadableByStandardTools() throws {
        let dir = try makeTemporaryDirectory(self)
        let url = dir.appendingPathComponent("out.zip")
        try makeArchive(sampleAppFiles()).write(to: url)

        let unzip = try runTool("/usr/bin/unzip", ["-t", url.path])
        XCTAssertEqual(unzip.status, 0, unzip.output)
        XCTAssertTrue(unzip.output.contains("No errors detected"), unzip.output)

        let python = "/usr/bin/python3"
        if FileManager.default.isExecutableFile(atPath: python) {
            let result = try runTool(python, ["-I", "-c", "import sys, zipfile; z = zipfile.ZipFile(sys.argv[1]); assert z.testzip() is None; print(sorted(z.namelist()))", url.path])
            XCTAssertEqual(result.status, 0, result.output)
            XCTAssertTrue(result.output.contains("assets/icon.png"), result.output)
        }
    }

    func testReadsArchivesFromStandardTools() throws {
        let dir = try makeTemporaryDirectory(self)
        let app = dir.appendingPathComponent("Sample")
        try writeFiles(sampleAppFiles(), to: app)
        try Data("x".utf8).write(to: app.appendingPathComponent(".DS_Store"))

        // Info-ZIP, as used by `zip -r App.japp .`
        let zipped = dir.appendingPathComponent("zip.japp")
        let zip = try runTool("/usr/bin/zip", ["-r", "-X", zipped.path, "."], in: app)
        XCTAssertEqual(zip.status, 0, zip.output)
        let fromZip = try JAppPackage.load(from: zipped)
        XCTAssertEqual(fromZip.manifest.id, "com.example.test")
        XCTAssertEqual(try fromZip.resources.data(at: "app.js"), Data("console.log('hi')".utf8))

        // ditto, as used by Finder's "Compress" (wraps the folder and adds __MACOSX resource forks).
        let dittoed = dir.appendingPathComponent("ditto.japp")
        let ditto = try runTool("/usr/bin/ditto", ["-c", "-k", "--sequesterRsrc", "--keepParent", app.path, dittoed.path])
        XCTAssertEqual(ditto.status, 0, ditto.output)
        let fromDitto = try JAppPackage.load(from: dittoed)
        XCTAssertEqual(fromDitto.manifest.name, "Test App")
        XCTAssertEqual((fromDitto.resources as? ZipResourceProvider)?.rootPrefix, "Sample/")
        XCTAssertFalse(fromDitto.resources.filePaths.contains(".DS_Store"))
    }

    func testIgnoresFinderArtefacts() throws {
        let archive = try ZipArchive(data: try makeArchive([
            ("manifest.json", Data("{}".utf8)),
            ("__MACOSX/._manifest.json", Data("junk".utf8)),
            ("assets/.DS_Store", Data("junk".utf8)),
            ("._index.html", Data("junk".utf8)),
        ]))
        XCTAssertEqual(archive.entries.map(\.path), ["manifest.json"])
    }

    // MARK: Hostile archives

    func testRejectsPathTraversal() throws {
        let hostile = ["../evil.txt", "a/../../evil.txt", "/etc/passwd", "a\\..\\evil.txt", "C:/evil.txt",
                       "a/./b.txt", "a//b.txt", "bad\u{0}name", "line\nbreak"]
        for name in hostile {
            let data = try makeArchive([("manifest.json", Data("{}".utf8)), (name, Data("x".utf8))])
            XCTAssertThrowsError(try ZipArchive(data: data), name) { error in
                guard case ArchiveError.unsafePath = error else { return XCTFail("\(name): unexpected \(error)") }
            }
        }
    }

    func testRejectsSymbolicLinks() throws {
        var writer = ZipWriter()
        try writer.addFile(path: "link", contents: Data("/etc/passwd".utf8), externalAttributes: UInt32(0o120777) << 16)
        XCTAssertThrowsError(try ZipArchive(data: try writer.finish())) { error in
            XCTAssertEqual(error as? ArchiveError, .symbolicLink("link"))
        }
    }

    func testRejectsCaseInsensitiveDuplicates() throws {
        let data = try makeArchive([("Index.html", Data("a".utf8)), ("index.html", Data("b".utf8))])
        XCTAssertThrowsError(try ZipArchive(data: data)) { error in
            XCTAssertEqual(error as? ArchiveError, .duplicateEntry("index.html"))
        }
    }

    func testRejectsEncryptedEntries() throws {
        var writer = ZipWriter()
        try writer.addFile(path: "secret.txt", contents: Data("x".utf8), flags: 0x0801)
        XCTAssertThrowsError(try ZipArchive(data: try writer.finish())) { error in
            guard case ArchiveError.unsupported = error else { return XCTFail("unexpected \(error)") }
        }
    }

    func testRejectsUnsupportedCompressionMethod() throws {
        var data = try makeArchive([("a.txt", Data(String(repeating: "a", count: 100).utf8))])
        for offset in data.offsets(ofSignature: localSignature) { data.write(u16: 12, at: offset + 8) }
        for offset in data.offsets(ofSignature: centralSignature) { data.write(u16: 12, at: offset + 10) }
        XCTAssertThrowsError(try ZipArchive(data: data)) { error in
            guard case ArchiveError.unsupported = error else { return XCTFail("unexpected \(error)") }
        }
    }

    func testDetectsCorruptedData() throws {
        let payload = Data("stored payload".utf8)
        var data = try makeArchive([("a.bin", payload)])
        let entry = try XCTUnwrap(try ZipArchive(data: data).entry(at: "a.bin"))
        data[entry.dataOffset] ^= 0xFF
        let archive = try ZipArchive(data: data)
        XCTAssertThrowsError(try archive.contents(of: XCTUnwrap(archive.entry(at: "a.bin")))) { error in
            XCTAssertEqual(error as? ArchiveError, .checksumMismatch("a.bin"))
        }
    }

    func testRejectsEntriesThatLieAboutTheirSize() throws {
        // A "zip bomb": 4 MB of zeros that claims to be 1 KB.
        var data = try makeArchive([("bomb.txt", Data(count: 4 * 1024 * 1024))])
        for offset in data.offsets(ofSignature: localSignature) { data.write(u32: 1024, at: offset + 22) }
        for offset in data.offsets(ofSignature: centralSignature) { data.write(u32: 1024, at: offset + 24) }
        let archive = try ZipArchive(data: data)
        XCTAssertThrowsError(try archive.contents(of: XCTUnwrap(archive.entry(at: "bomb.txt"))))
    }

    func testEnforcesLimits() throws {
        let data = try makeArchive((0..<5).map { ("f\($0).txt", Data(count: 1000)) })
        var limits = ArchiveLimits()
        limits.maxEntryCount = 3
        XCTAssertThrowsError(try ZipArchive(data: data, limits: limits))

        limits = ArchiveLimits()
        limits.maxTotalUncompressedSize = 4000
        XCTAssertThrowsError(try ZipArchive(data: data, limits: limits))

        limits = ArchiveLimits()
        limits.maxEntrySize = 999
        XCTAssertThrowsError(try ZipArchive(data: data, limits: limits))

        limits = ArchiveLimits()
        limits.maxArchiveSize = 100
        XCTAssertThrowsError(try ZipArchive(data: data, limits: limits))
    }

    func testRejectsGarbageAndTruncation() throws {
        XCTAssertThrowsError(try ZipArchive(data: Data("not a zip at all, just text".utf8))) { error in
            XCTAssertEqual(error as? ArchiveError, .notAZipArchive)
        }
        let data = try makeArchive(sampleAppFiles())
        XCTAssertThrowsError(try ZipArchive(data: data.prefix(data.count - 10)))
        XCTAssertThrowsError(try ZipArchive(data: data.suffix(from: 40)))
    }
}
