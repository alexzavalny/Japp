import Foundation
import XCTest
@testable import JAppKit

final class ManifestTests: XCTestCase {
    private func parse(_ json: String) -> Manifest.ParseResult { Manifest.parse(Data(json.utf8)) }

    func testParsesFullManifest() throws {
        let result = parse("""
        {
          "manifestVersion": 1,
          "id": "com.example.calculator",
          "name": "Calculator",
          "version": "1.2.3-beta.1",
          "description": "A simple calculator",
          "author": "Example",
          "entry": "index.html",
          "icon": "assets/icon.png",
          "window": { "width": 400, "height": 550, "minWidth": 300, "minHeight": 400, "maxWidth": 1000,
                      "resizable": false, "titleBarStyle": "transparent", "backgroundColor": "#1C1C1E" },
          "permissions": ["storage", "dialog", "notifications", "clipboard", "network"],
          "somethingFromTheFuture": { "ignored": true }
        }
        """)
        XCTAssertEqual(result.issues, [])
        let manifest = try XCTUnwrap(result.manifest)
        XCTAssertEqual(manifest.id, "com.example.calculator")
        XCTAssertEqual(manifest.name, "Calculator")
        XCTAssertEqual(manifest.version, "1.2.3-beta.1")
        XCTAssertEqual(manifest.description, "A simple calculator")
        XCTAssertEqual(manifest.icon, "assets/icon.png")
        XCTAssertEqual(manifest.window.width, 400)
        XCTAssertEqual(manifest.window.minHeight, 400)
        XCTAssertEqual(manifest.window.maxWidth, 1000)
        XCTAssertFalse(manifest.window.resizable)
        XCTAssertEqual(manifest.window.titleBarStyle, .transparent)
        XCTAssertEqual(manifest.window.backgroundColor, "#1C1C1E")
        XCTAssertEqual(manifest.permissions, Set(Permission.allCases))
    }

    func testDefaults() throws {
        let manifest = try XCTUnwrap(parse(#"{"manifestVersion":1,"id":"a.b","name":"A","version":"1"}"#).manifest)
        XCTAssertEqual(manifest.entry, "index.html")
        XCTAssertNil(manifest.icon)
        XCTAssertEqual(manifest.window, WindowOptions())
        XCTAssertTrue(manifest.permissions.isEmpty)
    }

    func testReportsEveryMissingField() {
        let result = parse("{}")
        XCTAssertNil(result.manifest)
        XCTAssertEqual(Set(result.errors.compactMap(\.field)), ["manifestVersion", "id", "name", "version"])
    }

    func testReadableJSONSyntaxError() {
        let result = parse("{ \"id\": \"a.b\" \"name\": 1 }")
        XCTAssertNil(result.manifest)
        XCTAssertTrue(result.errors.first?.message.contains("not valid JSON") == true, "\(result.issues)")
        XCTAssertNotNil(parse("[1, 2]").errors.first)
    }

    func testRejectsNewerManifestVersion() {
        let result = parse(#"{"manifestVersion":2,"id":"a.b","name":"A","version":"1"}"#)
        XCTAssertNil(result.manifest)
        XCTAssertTrue(result.errors.first?.message.contains("newer JApp Runtime") == true)
    }

    func testUnknownPermissionsAndStylesAreWarnings() throws {
        let result = parse(#"{"manifestVersion":1,"id":"a.b","name":"A","version":"1","permissions":["storage","teleport"],"window":{"titleBarStyle":"glass"}}"#)
        let manifest = try XCTUnwrap(result.manifest)
        XCTAssertEqual(manifest.permissions, [.storage])
        XCTAssertEqual(manifest.unknownPermissions, ["teleport"])
        XCTAssertEqual(manifest.window.titleBarStyle, .default)
        XCTAssertEqual(result.warnings.count, 2)
        XCTAssertTrue(result.errors.isEmpty)
    }

    func testHiddenTitleBarsAndMaterials() throws {
        let hidden = try XCTUnwrap(parse(#"{"manifestVersion":1,"id":"a.b","name":"A","version":"1","window":{"titleBarStyle":"hiddenInset","material":"sidebar"}}"#).manifest)
        XCTAssertEqual(hidden.window.titleBarStyle, .hiddenInset)
        XCTAssertTrue(hidden.window.titleBarStyle.extendsUnderTitleBar)
        XCTAssertEqual(hidden.window.material, .sidebar)
        XCTAssertFalse(WindowOptions.TitleBarStyle.transparent.extendsUnderTitleBar)

        let unknown = parse(#"{"manifestVersion":1,"id":"a.b","name":"A","version":"1","window":{"material":"glass"}}"#)
        XCTAssertNil(try XCTUnwrap(unknown.manifest).window.material)
        XCTAssertEqual(unknown.warnings.map(\.field), ["window.material"])

        let wrongType = parse(#"{"manifestVersion":1,"id":"a.b","name":"A","version":"1","window":{"material":1}}"#)
        XCTAssertEqual(wrongType.errors.map(\.field), ["window.material"])
    }

    func testTypeAndRangeErrors() {
        let result = parse("""
        {"manifestVersion": 1, "id": "a.b", "name": "A", "version": "1",
         "window": {"width": "wide", "height": 50, "minWidth": 900, "resizable": "yes", "backgroundColor": "red"},
         "permissions": "storage"}
        """)
        XCTAssertNil(result.manifest)
        let fields = Set(result.errors.compactMap(\.field))
        XCTAssertTrue(fields.isSuperset(of: ["window.width", "window.height", "window.minWidth", "window.resizable",
                                             "window.backgroundColor", "permissions"]), "\(fields)")
    }

    func testBooleansAreNotNumbers() {
        let result = parse(#"{"manifestVersion":true,"id":"a.b","name":"A","version":"1","window":{"width":true}}"#)
        XCTAssertEqual(Set(result.errors.compactMap(\.field)), ["manifestVersion", "window.width"])
    }

    func testPathsMustStayInsideTheApp() {
        for path in ["../index.html", "/index.html", "pages/../../x.html"] {
            let result = parse(#"{"manifestVersion":1,"id":"a.b","name":"A","version":"1","entry":"\#(path)"}"#)
            XCTAssertEqual(result.errors.first?.field, "entry", path)
        }
        XCTAssertEqual(parse(#"{"manifestVersion":1,"id":"a.b","name":"A","version":"1","entry":"app.js"}"#).errors.first?.field, "entry")
        XCTAssertEqual(parse(#"{"manifestVersion":1,"id":"a.b","name":"A","version":"1","icon":"icon.bmp"}"#).errors.first?.field, "icon")
    }

    func testIdentifierRules() {
        for valid in ["com.example.calculator", "a.b", "dev.japp-tools.my-app2", "Com.Example.App"] {
            XCTAssertTrue(Manifest.isValidID(valid), valid)
        }
        for invalid in ["calculator", "com..example", ".com.example", "com.example.", "com.-example", "com.ex ample",
                        "com/example", "com.example_app", "../etc", "com.exämple", String(repeating: "a.", count: 70) + "a"] {
            XCTAssertFalse(Manifest.isValidID(invalid), invalid)
        }
    }

    func testVersionRules() {
        for valid in ["1", "1.0", "1.0.0", "10.20.30.40", "1.0.0-beta.2", "2.0.0+build.5"] {
            XCTAssertTrue(Manifest.isValidVersion(valid), valid)
        }
        for invalid in ["v1", "1.", "one", "1.0.0.0.0", ""] {
            XCTAssertFalse(Manifest.isValidVersion(invalid), invalid)
        }
    }
}
