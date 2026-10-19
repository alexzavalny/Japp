import Foundation
import XCTest
@testable import JAppKit

final class AppTemplateTests: XCTestCase {
    func testCreatesAValidArchiveNamedAfterTheFile() throws {
        let dir = try makeTemporaryDirectory(self)
        let url = dir.appendingPathComponent("Hello There.japp")
        let manifest = try AppTemplate.createArchive(at: url, id: "com.example.hello-there")
        XCTAssertEqual(manifest.name, "Hello There")
        XCTAssertEqual(manifest.id, "com.example.hello-there")
        XCTAssertEqual(manifest.permissions, [.storage])

        let report = PackageValidator.validate(url: url)
        XCTAssertTrue(report.isValid, "\(report.issues)")
        XCTAssertEqual(report.warnings, [])
        let package = try JAppPackage.load(from: url)
        XCTAssertEqual(package.resources.filePaths, ["AGENTS.md", "app.js", "assets/icon.png", "index.html", "manifest.json", "style.css"])
        XCTAssertNotNil(package.iconData.flatMap { NSImage(data: $0) }, "the icon is a readable image")
        let html = String(decoding: try package.resources.data(at: "index.html") ?? Data(), as: UTF8.self)
        XCTAssertTrue(html.contains("<title>Hello There</title>"))
        XCTAssertTrue(html.contains("Hello, World!"))
        let agents = String(decoding: try package.resources.data(at: "AGENTS.md") ?? Data(), as: UTF8.self)
        XCTAssertTrue(agents.hasPrefix("# Hello There — notes for AI coding agents"))
        XCTAssertTrue(agents.contains("japp save \"<archivePath>\" --run"))
        XCTAssertTrue(agents.contains("## Icon"), "agents are asked to replace the placeholder icon")
        XCTAssertTrue(agents.contains("japp export"), "agents know how to make a standalone app")
    }

    /// AGENTS.md tells agents that `../session.json` names the `.japp` of an Edit Source workspace.
    func testAgentsGuideMatchesTheWorkspaceLayout() throws {
        let dir = try makeTemporaryDirectory(self)
        let url = dir.appendingPathComponent("Notes.japp")
        try AppTemplate.createArchive(at: url, id: "com.example.notes")
        let (workspace, _) = try SourceWorkspace.open(archiveURL: url, workspaces: dir.appendingPathComponent("Workspaces"))
        let guide = try String(contentsOf: workspace.sourceURL.appendingPathComponent("AGENTS.md"), encoding: .utf8)
        XCTAssertTrue(guide.contains("`../session.json`"))
        let session = workspace.sourceURL.deletingLastPathComponent().appendingPathComponent("session.json")
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: session)) as? [String: Any]
        XCTAssertEqual((object?["archivePath"] as? String).map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path },
                       url.resolvingSymlinksInPath().path)
    }

    func testReplacesAnExistingFileAndTheResultIsEditable() throws {
        let dir = try makeTemporaryDirectory(self)
        let url = dir.appendingPathComponent("App.japp")
        try Data("not a zip".utf8).write(to: url)
        try AppTemplate.createArchive(at: url, id: "com.example.app")
        let (workspace, outcome) = try SourceWorkspace.open(archiveURL: url, workspaces: dir.appendingPathComponent("Workspaces"))
        XCTAssertEqual(outcome, .created)
        XCTAssertEqual(try workspace.changes(), [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: workspace.sourceURL.appendingPathComponent("app.js").path))
    }

    func testNamesAreEscapedWhereverTheyAppear() throws {
        let dir = try makeTemporaryDirectory(self)
        let url = dir.appendingPathComponent("x.japp")
        let manifest = try AppTemplate.createArchive(at: url, name: #"<b>"Q" & A</b>"#, id: "com.example.qa")
        XCTAssertEqual(manifest.name, #"<b>"Q" & A</b>"#, "the manifest is valid JSON whatever the name")
        let html = String(decoding: try JAppPackage.load(from: url).resources.data(at: "index.html") ?? Data(), as: UTF8.self)
        XCTAssertTrue(html.contains("<title>&lt;b&gt;&quot;Q&quot; &amp; A&lt;/b&gt;</title>"))
        XCTAssertFalse(html.contains("<b>"))
    }

    func testAppNamesAreCleanedUp() {
        XCTAssertEqual(AppTemplate.appName(from: "  Notes \n"), "Notes")
        XCTAssertEqual(AppTemplate.appName(from: "A\u{7}B"), "AB")
        XCTAssertEqual(AppTemplate.appName(from: "   "), AppTemplate.defaultName)
        XCTAssertEqual(AppTemplate.appName(from: String(repeating: "x", count: 300)).count, 100)
    }

    func testSuggestedIDs() {
        let free: (String) -> Bool = { _ in false }
        XCTAssertEqual(AppTemplate.suggestedID(forName: "Todo List", isTaken: free), "com.example.todo-list")
        XCTAssertEqual(AppTemplate.suggestedID(forName: "Café Menü!", isTaken: free), "com.example.cafe-menu")
        XCTAssertEqual(AppTemplate.suggestedID(forName: "Калькулятор", isTaken: free), "com.example.kal-kulator")
        XCTAssertEqual(AppTemplate.suggestedID(forName: "🙂", isTaken: free), "com.example.app")
        XCTAssertEqual(AppTemplate.suggestedID(forName: String(repeating: "ab ", count: 40), isTaken: free).hasSuffix("-"), false)

        let taken: Set = ["com.example.notes", "com.example.notes-2"]
        XCTAssertEqual(AppTemplate.suggestedID(forName: "Notes", isTaken: taken.contains), "com.example.notes-3")

        for name in ["Todo List", "Café Menü!", "Калькулятор", "🙂", "日本語のアプリ", "--", String(repeating: "ab ", count: 40)] {
            XCTAssertTrue(Manifest.isValidID(AppTemplate.suggestedID(forName: name, isTaken: free)), name)
        }
    }

    func testCreatesAFolder() throws {
        let dir = try makeTemporaryDirectory(self)
        let folder = dir.appendingPathComponent("Todo List")
        let manifest = try AppTemplate.createFolder(at: folder, id: "com.example.todo-list")
        XCTAssertEqual(manifest.name, "Todo List")
        XCTAssertTrue(PackageValidator.validate(url: folder).isValid)
    }
}
