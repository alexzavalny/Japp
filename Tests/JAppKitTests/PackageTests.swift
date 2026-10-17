import Foundation
import XCTest
@testable import JAppKit

final class PackageTests: XCTestCase {
    func testLoadsArchive() throws {
        let dir = try makeTemporaryDirectory(self)
        let url = dir.appendingPathComponent("Test.japp")
        try makeArchive(sampleAppFiles()).write(to: url)

        let package = try JAppPackage.load(from: url)
        XCTAssertEqual(package.kind, .archive)
        XCTAssertEqual(package.manifest.id, "com.example.test")
        XCTAssertEqual(package.iconData, tinyPNG)
        XCTAssertNotNil(package.archiveDigest)
        XCTAssertEqual(try package.resources.data(at: "style.css"), Data("body { color: red; }".utf8))
        XCTAssertEqual(try package.resources.data(at: "STYLE.CSS"), Data("body { color: red; }".utf8), "case-insensitive fallback")
        XCTAssertNil(try package.resources.data(at: "missing.js"))
        XCTAssertEqual(package.resources.filePaths, ["app.js", "assets/icon.png", "index.html", "manifest.json", "style.css"])
    }

    func testFindsManifestInsideSingleTopLevelFolder() throws {
        let files = sampleAppFiles().map { ("Wrapped/" + $0.key, $0.value) }.sorted { $0.0 < $1.0 }
        let package = try JAppPackage.load(archiveData: try makeArchive(files), url: URL(fileURLWithPath: "/x.japp"))
        XCTAssertEqual(try package.resources.data(at: "app.js"), Data("console.log('hi')".utf8))
    }

    func testMissingManifestAndEntry() throws {
        var files = sampleAppFiles()
        files.removeValue(forKey: "manifest.json")
        XCTAssertThrowsError(try JAppPackage.load(archiveData: try makeArchive(files), url: URL(fileURLWithPath: "/x.japp"))) { error in
            guard case JAppError.manifestMissing = error else { return XCTFail("unexpected \(error)") }
        }

        files = sampleAppFiles()
        files.removeValue(forKey: "index.html")
        XCTAssertThrowsError(try JAppPackage.load(archiveData: try makeArchive(files), url: URL(fileURLWithPath: "/x.japp"))) { error in
            guard case JAppError.entryMissing("index.html") = error else { return XCTFail("unexpected \(error)") }
        }
    }

    func testMissingIconIsOnlyAWarning() throws {
        var files = sampleAppFiles()
        files.removeValue(forKey: "assets/icon.png")
        let package = try JAppPackage.load(archiveData: try makeArchive(files), url: URL(fileURLWithPath: "/x.japp"))
        XCTAssertNil(package.iconData)
        XCTAssertEqual(package.warnings.first?.field, "icon")
    }

    func testDirectoryProviderStaysInsideTheFolder() throws {
        let dir = try makeTemporaryDirectory(self)
        let app = dir.appendingPathComponent("App")
        try writeFiles(sampleAppFiles(), to: app)
        try Data("secret".utf8).write(to: dir.appendingPathComponent("secret.txt"))
        try FileManager.default.createSymbolicLink(at: app.appendingPathComponent("escape.txt"),
                                                   withDestinationURL: dir.appendingPathComponent("secret.txt"))

        let package = try JAppPackage.load(from: app)
        XCTAssertEqual(package.kind, .directory)
        XCTAssertEqual(try package.resources.data(at: "app.js"), Data("console.log('hi')".utf8))
        XCTAssertNil(try package.resources.data(at: "escape.txt"), "symlink out of the app must not resolve")
        XCTAssertNil(try package.resources.data(at: "../secret.txt"))
    }

    // MARK: Packager

    func testPackExcludesHiddenFilesAndRoundTrips() throws {
        let dir = try makeTemporaryDirectory(self)
        let app = dir.appendingPathComponent("App")
        var files = sampleAppFiles()
        files[".DS_Store"] = Data("x".utf8)
        files[".git/config"] = Data("x".utf8)
        files["notes.txt~"] = Data("x".utf8)
        files["assets/.hidden"] = Data("x".utf8)
        try writeFiles(files, to: app)

        // Packing into the app folder itself must not include the output.
        let output = app.appendingPathComponent("App.japp")
        let result = try Packager.pack(directory: app, to: output)
        XCTAssertEqual(result.fileCount, 5)
        XCTAssertEqual(result.manifest.name, "Test App")

        let package = try JAppPackage.load(from: output)
        XCTAssertEqual(package.resources.filePaths, ["app.js", "assets/icon.png", "index.html", "manifest.json", "style.css"])

        // Packing again replaces the archive in place.
        try Data("console.log('v2')".utf8).write(to: app.appendingPathComponent("app.js"))
        try Packager.pack(directory: app, to: output)
        XCTAssertEqual(try JAppPackage.load(from: output).resources.data(at: "app.js"), Data("console.log('v2')".utf8))
    }

    func testPackRejectsInvalidAppsAndSymlinks() throws {
        let dir = try makeTemporaryDirectory(self)
        let app = dir.appendingPathComponent("App")
        try writeFiles(sampleAppFiles(manifest: #"{"manifestVersion":1,"name":"No ID"}"#), to: app)
        let output = dir.appendingPathComponent("App.japp")
        XCTAssertThrowsError(try Packager.pack(directory: app, to: output))
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))

        try writeFiles(sampleAppFiles(), to: app)
        try FileManager.default.createSymbolicLink(atPath: app.appendingPathComponent("link.txt").path, withDestinationPath: "/etc/hosts")
        XCTAssertThrowsError(try Packager.pack(directory: app, to: output)) { error in
            XCTAssertTrue("\(error)".contains("symbolic link"), "\(error)")
        }
    }

    func testAtomicWriteLeavesOriginalOnFailure() throws {
        let dir = try makeTemporaryDirectory(self)
        let locked = dir.appendingPathComponent("locked")
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        let target = locked.appendingPathComponent("App.japp")
        try Data("original".utf8).write(to: target)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }

        XCTAssertThrowsError(try Packager.writeAtomically(Data("replacement".utf8), to: target))
        XCTAssertEqual(try Data(contentsOf: target), Data("original".utf8))
    }

    func testSafeExtraction() throws {
        let dir = try makeTemporaryDirectory(self)
        let archive = try ZipArchive(data: try makeArchive(sampleAppFiles()))
        let digests = try Packager.extract(archive, rootPrefix: "", to: dir.appendingPathComponent("out"))
        XCTAssertEqual(digests.count, 5)
        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent("out/assets/icon.png")), tinyPNG)
    }

    // MARK: Validator

    func testValidatorWarnsAboutBlockedRemoteResources() throws {
        let dir = try makeTemporaryDirectory(self)
        let app = dir.appendingPathComponent("App")
        try writeFiles(sampleAppFiles(html: #"<script src="https://cdn.example.com/lib.js"></script>"#), to: app)
        let report = PackageValidator.validate(url: app)
        XCTAssertTrue(report.isValid)
        XCTAssertTrue(report.warnings.contains { $0.message.contains("network") }, "\(report.issues)")
        XCTAssertTrue(report.warnings.contains { $0.message.contains("1×1") }, "small icon warning: \(report.issues)")
    }

    func testValidatorReportsManifestErrors() throws {
        let dir = try makeTemporaryDirectory(self)
        let app = dir.appendingPathComponent("App")
        try writeFiles(sampleAppFiles(manifest: #"{"manifestVersion":1,"id":"bad","name":"A","version":"1"}"#), to: app)
        let report = PackageValidator.validate(url: app)
        XCTAssertFalse(report.isValid)
        XCTAssertEqual(report.errors.first?.field, "id")
    }

    func testMIMETypes() {
        XCTAssertEqual(MIMEType.forPath("app.js"), "text/javascript")
        XCTAssertEqual(MIMEType.forPath("lib/mod.mjs"), "text/javascript")
        XCTAssertEqual(MIMEType.forPath("style.CSS"), "text/css")
        XCTAssertEqual(MIMEType.forPath("index.html"), "text/html")
        XCTAssertEqual(MIMEType.forPath("icon.svg"), "image/svg+xml")
        XCTAssertEqual(MIMEType.forPath("font.woff2"), "font/woff2")
        XCTAssertEqual(MIMEType.forPath("module.wasm"), "application/wasm")
        XCTAssertEqual(MIMEType.forPath("unknown.zzz"), "application/octet-stream")
    }
}
