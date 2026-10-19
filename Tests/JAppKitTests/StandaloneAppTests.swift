import Foundation
import XCTest
@testable import JAppKit

final class StandaloneAppTests: XCTestCase {
    private var dir: URL!
    private var runtime: StandaloneApp.Runtime!
    private var archive: URL { dir.appendingPathComponent("Test App.japp") }
    private var output: URL { dir.appendingPathComponent("out/Test App.app") }

    override func setUpWithError() throws {
        dir = try makeTemporaryDirectory(self)
        // Any signed Mach-O files stand in for JApp Runtime's launcher and library.
        let launcher = dir.appendingPathComponent("launcher"), library = dir.appendingPathComponent("library.dylib")
        for file in [launcher, library] { try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: file) }
        let entitlements = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Resources/JAppRuntime.entitlements")
        runtime = StandaloneApp.Runtime(launcher: launcher, library: library, entitlements: entitlements)
        try makeArchive(sampleAppFiles(manifest: manifest())).write(to: archive)
    }

    private func manifest(version: String = "1.0.0") -> String {
        minimalManifest.replacingOccurrences(of: #""version": "1.0.0""#, with: #""version": "\#(version)", "author": "Ada""#)
    }

    private func info(_ app: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: app.appendingPathComponent("Contents/Info.plist"))
        return try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    }

    private func inode(_ url: URL) throws -> Int {
        try XCTUnwrap(FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber] as? Int)
    }

    func testExportsASignedAppWithTheRuntimeAndTheArchiveInside() throws {
        let result = try StandaloneApp.export(archive, to: output, runtime: runtime)
        XCTAssertEqual(result.url.path, output.path)
        XCTAssertEqual(result.manifest.id, "com.example.test")
        let contents = output.appendingPathComponent("Contents")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: contents.appendingPathComponent("MacOS/Test App").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: contents.appendingPathComponent("Frameworks/libJAppRuntimeCore.dylib").path),
                      "the launcher loads ../Frameworks first, so no installed runtime is needed")
        XCTAssertEqual(try Data(contentsOf: contents.appendingPathComponent("Resources/Test App.japp")), try Data(contentsOf: archive),
                       "the app is embedded unchanged")
        XCTAssertNotNil(ICNS.elements(of: try Data(contentsOf: contents.appendingPathComponent("Resources/AppIcon.icns"))))
        XCTAssertGreaterThan(result.size, try Data(contentsOf: archive).count)

        let info = try info(output)
        XCTAssertEqual(info["CFBundleIdentifier"] as? String, "com.example.test", "a real app id, not dev.japp.app.…")
        XCTAssertEqual(info["CFBundleExecutable"] as? String, "Test App")
        XCTAssertEqual(info["CFBundleName"] as? String, "Test App")
        XCTAssertEqual(info["NSHumanReadableCopyright"] as? String, "Ada")
        XCTAssertNil(info[AppBundle.runtimePathKey], "it must not depend on an installed JApp Runtime")
        let fields = try XCTUnwrap(info[AppBundle.infoKey] as? [String: Any])
        XCTAssertEqual(fields[StandaloneApp.archiveKey] as? String, "Test App.japp")
        XCTAssertEqual(fields["runtimeVersion"] as? String, JAppVersion.runtime)
        XCTAssertEqual(AppBundle.Identity(infoDictionary: info)?.appID, "com.example.test", "the runtime sees an app bundle")
        for key in ["CFBundleDocumentTypes", "CFBundleURLTypes", "NSServices", "UTExportedTypeDeclarations", "LSUIElement"] {
            XCTAssertNil(info[key], "a standalone app must never become a handler: \(key)")
        }

        XCTAssertEqual(try runTool("/usr/bin/codesign", ["--verify", "--strict", "--deep", output.path]).status, 0)
        let details = try runTool("/usr/bin/codesign", ["-d", "--verbose=2", "--entitlements", "-", output.path]).output
        XCTAssertTrue(details.contains("runtime"), "hardened runtime: \(details)")
        XCTAssertTrue(details.contains("disable-library-validation"), "the entitlement that lets it load the library")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: output.deletingLastPathComponent().path), ["Test App.app"],
                       "no staging folder left behind")
    }

    func testDropsExtendedAttributesThatWouldBreakTheSignature() throws {
        for (name, value) in [("com.apple.quarantine", "0081;00000000;Safari;"), ("dev.japp.icon-digest", "abc")] {
            XCTAssertEqual(setxattr(archive.path, name, value, value.utf8.count, 0, 0), 0)
        }
        try StandaloneApp.export(archive, to: output, runtime: runtime)
        let embedded = output.appendingPathComponent("Contents/Resources/Test App.japp")
        for name in ["com.apple.quarantine", "dev.japp.icon-digest"] {
            XCTAssertEqual(getxattr(embedded.path, name, nil, 0, 0, 0), -1, "\(name) is not copied into the bundle")
        }
        XCTAssertEqual(try runTool("/usr/bin/codesign", ["--verify", "--strict", "--deep", output.path]).status, 0)
    }

    func testReplacesAnExistingAppOnlyWhenAsked() throws {
        try StandaloneApp.export(archive, to: output, runtime: runtime)
        let executable = output.appendingPathComponent("Contents/MacOS/Test App")
        let first = try inode(executable)
        XCTAssertThrowsError(try StandaloneApp.export(archive, to: output, runtime: runtime))
        XCTAssertEqual(try inode(executable), first, "the existing app is untouched")

        try makeArchive(sampleAppFiles(manifest: manifest(version: "2.0.0"))).write(to: archive)
        try StandaloneApp.export(archive, to: output, runtime: runtime, replacing: true)
        XCTAssertEqual(try info(output)["CFBundleShortVersionString"] as? String, "2.0.0")
        XCTAssertNotEqual(try inode(executable), first)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: output.deletingLastPathComponent().path), ["Test App.app"])
    }

    func testExportsAnAppFolder() throws {
        let folder = dir.appendingPathComponent("Test App")
        try writeFiles(sampleAppFiles(manifest: manifest()), to: folder)
        try StandaloneApp.export(folder, to: output, runtime: runtime)
        let embedded = try JAppPackage.load(from: output.appendingPathComponent("Contents/Resources/Test App.japp"))
        XCTAssertEqual(embedded.kind, .archive)
        XCTAssertEqual(embedded.manifest.id, "com.example.test")
        XCTAssertEqual(try embedded.resources.data(at: "app.js"), Data("console.log('hi')".utf8))
    }

    func testRefusesToExportIntoTheAppsOwnFolder() throws {
        let folder = dir.appendingPathComponent("Test App")
        try writeFiles(sampleAppFiles(manifest: manifest()), to: folder)
        XCTAssertThrowsError(try StandaloneApp.export(folder, to: folder.appendingPathComponent("Test App.app"), runtime: runtime),
                             "the next pack of the folder would put the app inside the .japp")
        XCTAssertThrowsError(try StandaloneApp.export(folder, to: folder.appendingPathComponent("out/Test App.app"), runtime: runtime))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted(),
                       ["app.js", "assets", "index.html", "manifest.json", "style.css"], "nothing written into the folder")
        XCTAssertTrue(StandaloneApp.isInside(folder.appendingPathComponent("Test App.app"), folder: folder))
        XCTAssertFalse(StandaloneApp.isInside(dir.appendingPathComponent("Test App.app"), folder: folder))
        XCTAssertFalse(StandaloneApp.isInside(dir.appendingPathComponent("Test App 2/x.app"), folder: folder), "a sibling with a longer name")
        XCTAssertFalse(StandaloneApp.isInside(output, folder: archive), "a .japp file is not a folder")
        // The same folder spelled through /private (as `cd` and Terminal often report it), into a new subfolder.
        let path = folder.path, other = path.hasPrefix("/private/") ? String(path.dropFirst("/private".count)) : "/private" + path
        XCTAssertTrue(StandaloneApp.isInside(URL(fileURLWithPath: other).appendingPathComponent("new/Test App.app"), folder: folder), other)
        try StandaloneApp.export(folder, to: dir.appendingPathComponent("Test App.app"), runtime: runtime)
    }

    func testAnInvalidAppWritesNothing() throws {
        let folder = dir.appendingPathComponent("Broken")
        try writeFiles(["manifest.json": Data(#"{"manifestVersion":1,"id":"nope"}"#.utf8), "index.html": Data()], to: folder)
        XCTAssertThrowsError(try StandaloneApp.export(folder, to: output, runtime: runtime)) { error in
            guard case JAppError.invalidManifest = error else { return XCTFail("\(error)") }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.deletingLastPathComponent().path))
        XCTAssertThrowsError(try StandaloneApp.export(archive, to: dir.appendingPathComponent("Test App"), runtime: runtime),
                             "the destination must be an .app")
    }

    func testRuntimeAppMustBeComplete() throws {
        let app = dir.appendingPathComponent("JApp Runtime.app")
        try writeFiles(["Contents/MacOS/JAppRuntime": Data("x".utf8)], to: app)
        XCTAssertThrowsError(try StandaloneApp.Runtime(app: app), "no library")
        try writeFiles(["Contents/Frameworks/libJAppRuntimeCore.dylib": Data("x".utf8)], to: app)
        let parts = try StandaloneApp.Runtime(app: app)
        XCTAssertEqual(parts.library.lastPathComponent, "libJAppRuntimeCore.dylib")
        XCTAssertNil(parts.entitlements, "missing entitlements: signed without the hardened runtime")
    }
}
