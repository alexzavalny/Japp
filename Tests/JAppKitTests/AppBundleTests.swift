import Foundation
import ImageIO
import XCTest
@testable import JAppKit

final class AppBundleTests: XCTestCase {
    private var dir: URL!
    private var root: URL { dir.appendingPathComponent("AppBundles") }
    private var launcher: URL { dir.appendingPathComponent("launcher") }

    override func setUpWithError() throws {
        dir = try makeTemporaryDirectory(self)
        // Any signed executable stands in for JApp Runtime's launcher.
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: launcher)
    }

    private func manifest(name: String = "Calculator", version: String = "1.2.0-beta.1") throws -> Manifest {
        try XCTUnwrap(Manifest.parse(Data(#"{"manifestVersion":1,"id":"Com.Example.Calc","name":"\#(name)","version":"\#(version)"}"#.utf8)).manifest)
    }

    private func prepare(_ manifest: Manifest, icon: Data? = squarePNG(48)) throws -> AppBundle {
        try AppBundle.prepare(for: manifest, iconData: icon, launcher: launcher, entitlements: nil,
                              runtimeApp: URL(fileURLWithPath: "/Applications/JApp Runtime.app"), root: root)
    }

    private func info(_ bundle: AppBundle) throws -> [String: Any] {
        let data = try Data(contentsOf: bundle.url.appendingPathComponent("Contents/Info.plist"))
        return try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    }

    private func inode(_ url: URL) throws -> Int {
        try XCTUnwrap(FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber] as? Int)
    }

    func testIdentifiersAreNamespacedAndNamesAreFileNames() {
        XCTAssertEqual(AppBundle.bundleIdentifier(forAppID: "Com.Apple.Finder"), "dev.japp.app.com.apple.finder")
        XCTAssertEqual(AppBundle.fileName(for: "Chess Results"), "Chess Results")
        XCTAssertEqual(AppBundle.fileName(for: "AC/DC: Live"), "AC-DC- Live")
        XCTAssertEqual(AppBundle.fileName(for: "..hidden"), "hidden")
        XCTAssertEqual(AppBundle.fileName(for: " \n\t"), "App")
        XCTAssertEqual(AppBundle.fileName(for: "Line\nBreak"), "LineBreak")
        XCTAssertLessThanOrEqual(AppBundle.fileName(for: String(repeating: "Я", count: 150)).utf8.count, 200)
    }

    func testBuildsASignedBundleWithTheAppsIdentity() throws {
        let bundle = try prepare(try manifest())
        XCTAssertEqual(bundle.url, root.appendingPathComponent("com.example.calc/Calculator.app"))
        let info = try info(bundle)
        XCTAssertEqual(info["CFBundleIdentifier"] as? String, "dev.japp.app.com.example.calc")
        XCTAssertEqual(info["CFBundleName"] as? String, "Calculator")
        XCTAssertEqual(info["CFBundleExecutable"] as? String, "Calculator")
        XCTAssertEqual(info["CFBundleShortVersionString"] as? String, "1.2.0-beta.1")
        XCTAssertEqual(info["CFBundleVersion"] as? String, "1.2.0", "numbers and dots only")
        XCTAssertEqual(info["CFBundleIconFile"] as? String, "AppIcon")
        XCTAssertEqual(info["JAppRuntimePath"] as? String, "/Applications/JApp Runtime.app")
        for key in ["CFBundleDocumentTypes", "CFBundleURLTypes", "NSServices", "UTExportedTypeDeclarations", "LSUIElement"] {
            XCTAssertNil(info[key], "an app bundle must never become a handler: \(key)")
        }
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: bundle.executableURL.path))
        XCTAssertNotNil(ICNS.elements(of: try Data(contentsOf: bundle.url.appendingPathComponent("Contents/Resources/AppIcon.icns"))))
        XCTAssertEqual(try runTool("/usr/bin/codesign", ["--verify", "--strict", bundle.url.path]).status, 0)
        XCTAssertEqual(AppBundle.existing(forAppID: "com.example.calc", root: root), bundle)
        XCTAssertEqual(AppBundle.all(root: root), [bundle])
    }

    func testReusesACurrentBundleAndUpdatesInPlace() throws {
        let first = try prepare(try manifest())
        let contents = try inode(first.url.appendingPathComponent("Contents"))
        let folder = try inode(first.url)
        XCTAssertEqual(try inode(try prepare(try manifest()).url.appendingPathComponent("Contents")), contents, "unchanged app: no rebuild")

        // A new name renames the same folder (a Dock item keeps pointing at it) and swaps its contents.
        let renamed = try prepare(try manifest(name: "Calculator Pro", version: "2.0"))
        XCTAssertEqual(renamed.url.lastPathComponent, "Calculator Pro.app")
        XCTAssertEqual(try inode(renamed.url), folder)
        XCTAssertNotEqual(try inode(renamed.url.appendingPathComponent("Contents")), contents)
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.url.path))
        XCTAssertEqual(try info(renamed)["CFBundleName"] as? String, "Calculator Pro")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: renamed.url.deletingLastPathComponent().path)
            .filter { !$0.hasPrefix(".") }, ["Calculator Pro.app"], "no staging folders or old bundles left behind")

        let iconless = try prepare(try manifest(name: "Calculator Pro", version: "2.0"), icon: nil)
        XCTAssertNil(try info(iconless)["CFBundleIconFile"])
        XCTAssertEqual(iconless.identity.iconDigest, "")
    }

    func testICNSHasEveryStandardSize() throws {
        let icns = try XCTUnwrap(ICNS.make(fromImageData: try XCTUnwrap(rectanglePNG(width: 300, height: 200))))
        let elements = try XCTUnwrap(ICNS.elements(of: icns))
        XCTAssertEqual(elements.map(\.type), ICNS.elements.map(\.type))
        for (element, expected) in zip(elements, ICNS.elements) {
            let source = try XCTUnwrap(CGImageSourceCreateWithData(element.png as CFData, nil))
            let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
            XCTAssertEqual([image.width, image.height], [expected.pixels, expected.pixels], element.type)
        }
        XCTAssertNil(ICNS.make(fromImageData: Data("not an image".utf8)))
        XCTAssertNil(ICNS.elements(of: Data("icns\0\0\0\u{9}x".utf8)))
    }

    func testLaunchRecordFollowsAMovedFile() throws {
        _ = try prepare(try manifest())
        let file = dir.appendingPathComponent("Calc.japp")
        try Data("x".utf8).write(to: file)
        AppBundle.recordLaunch(of: file, appID: "Com.Example.Calc", root: root)
        XCTAssertEqual(AppBundle.lastLaunched(appID: "com.example.calc", root: root)?.path, file.path)

        let moved = dir.appendingPathComponent("Moved.japp")
        try FileManager.default.moveItem(at: file, to: moved)
        XCTAssertEqual(AppBundle.lastLaunched(appID: "com.example.calc", root: root)?.resolvingSymlinksInPath().path,
                       moved.resolvingSymlinksInPath().path, "the bookmark finds the file again")

        try FileManager.default.removeItem(at: moved)
        XCTAssertNil(AppBundle.lastLaunched(appID: "com.example.calc", root: root))
        XCTAssertNil(AppBundle.lastLaunched(appID: "com.example.other", root: root))
    }
}

private func squarePNG(_ size: Int) -> Data? { rectanglePNG(width: size, height: size) }

private func rectanglePNG(width: Int, height: Int) -> Data? {
    guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    context.setFillColor(CGColor(red: 1, green: 0.6, blue: 0, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    guard let image = context.makeImage() else { return nil }
    let data = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else { return nil }
    CGImageDestinationAddImage(destination, image, nil)
    return CGImageDestinationFinalize(destination) ? data as Data : nil
}
