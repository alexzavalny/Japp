import Foundation
import XCTest
@testable import JAppKit

final class SourceWorkspaceTests: XCTestCase {
    private var dir: URL!
    private var workspaces: URL { dir.appendingPathComponent("Workspaces") }
    private var archiveURL: URL { dir.appendingPathComponent("Test.japp") }

    override func setUpWithError() throws {
        dir = try makeTemporaryDirectory(self)
        try makeArchive(sampleAppFiles()).write(to: archiveURL)
    }

    func testOpenExtractsAndResumes() throws {
        let (workspace, outcome) = try SourceWorkspace.open(archiveURL: archiveURL, workspaces: workspaces)
        XCTAssertEqual(outcome, .created)
        XCTAssertEqual(workspace.sourceURL.lastPathComponent, "Test App", "source folder is named after the app")
        XCTAssertEqual(try String(contentsOf: workspace.sourceURL.appendingPathComponent("app.js"), encoding: .utf8), "console.log('hi')")
        XCTAssertEqual(try workspace.changes(), [])

        try Data("edited".utf8).write(to: workspace.sourceURL.appendingPathComponent("app.js"))
        let (resumed, again) = try SourceWorkspace.open(archiveURL: archiveURL, workspaces: workspaces)
        XCTAssertEqual(again, .resumed)
        XCTAssertEqual(resumed.rootURL, workspace.rootURL)
        XCTAssertEqual(try resumed.changes(), [.init(path: "app.js", kind: .modified)], "edits survive reopening")
    }

    func testTracksChanges() throws {
        let (workspace, _) = try SourceWorkspace.open(archiveURL: archiveURL, workspaces: workspaces)
        try Data("body{}".utf8).write(to: workspace.sourceURL.appendingPathComponent("style.css"))
        try Data("new".utf8).write(to: workspace.sourceURL.appendingPathComponent("extra.txt"))
        try FileManager.default.removeItem(at: workspace.sourceURL.appendingPathComponent("app.js"))
        try Data("ignored".utf8).write(to: workspace.sourceURL.appendingPathComponent(".DS_Store"))
        XCTAssertEqual(try workspace.changes(), [
            .init(path: "app.js", kind: .deleted),
            .init(path: "extra.txt", kind: .added),
            .init(path: "style.css", kind: .modified),
        ])
    }

    func testSaveRepacksAtomicallyAndKeepsBackup() throws {
        let (workspace, _) = try SourceWorkspace.open(archiveURL: archiveURL, workspaces: workspaces)
        let original = try Data(contentsOf: archiveURL)
        try Data("console.log('changed')".utf8).write(to: workspace.sourceURL.appendingPathComponent("app.js"))

        let result = try workspace.save()
        XCTAssertEqual(result.changes, [.init(path: "app.js", kind: .modified)])
        XCTAssertEqual(try JAppPackage.load(from: archiveURL).resources.data(at: "app.js"), Data("console.log('changed')".utf8))
        XCTAssertEqual(try workspace.changes(), [], "saved state becomes the new baseline")
        XCTAssertFalse(workspace.archiveChangedOnDisk())
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(result.backup)), original)
    }

    func testInvalidSourceIsNotSaved() throws {
        let (workspace, _) = try SourceWorkspace.open(archiveURL: archiveURL, workspaces: workspaces)
        let original = try Data(contentsOf: archiveURL)
        try Data("{ broken json".utf8).write(to: workspace.sourceURL.appendingPathComponent("manifest.json"))
        XCTAssertThrowsError(try workspace.save()) { error in
            guard case WorkspaceError.invalidSource = error else { return XCTFail("unexpected \(error)") }
        }
        XCTAssertEqual(try Data(contentsOf: archiveURL), original, "archive untouched")
    }

    func testDetectsExternalModification() throws {
        let (workspace, _) = try SourceWorkspace.open(archiveURL: archiveURL, workspaces: workspaces)
        var files = sampleAppFiles()
        files["app.js"] = Data("console.log('someone else')".utf8)
        try makeArchive(files).write(to: archiveURL)

        XCTAssertTrue(workspace.archiveChangedOnDisk())
        XCTAssertThrowsError(try workspace.save()) { error in
            guard case WorkspaceError.archiveChangedOnDisk = error else { return XCTFail("unexpected \(error)") }
        }
        XCTAssertEqual(try SourceWorkspace.open(archiveURL: archiveURL, workspaces: workspaces).1, .resumedArchiveChanged)
        try workspace.save(overwritingExternalChanges: true)
        XCTAssertEqual(try JAppPackage.load(from: archiveURL).resources.data(at: "app.js"), Data("console.log('hi')".utf8))
    }

    func testBrokenManifestCanStillBeEdited() throws {
        try makeArchive(sampleAppFiles(manifest: "{ oops")).write(to: archiveURL)
        XCTAssertThrowsError(try JAppPackage.load(from: archiveURL))

        let (workspace, outcome) = try SourceWorkspace.open(archiveURL: archiveURL, workspaces: workspaces)
        XCTAssertEqual(outcome, .created)
        XCTAssertEqual(workspace.sourceURL.lastPathComponent, "Test", "falls back to the file name")
        try Data(minimalManifest.utf8).write(to: workspace.sourceURL.appendingPathComponent("manifest.json"))
        try workspace.save()
        XCTAssertEqual(try JAppPackage.load(from: archiveURL).manifest.name, "Test App")
    }

    func testDiscardAndRemove() throws {
        let (workspace, _) = try SourceWorkspace.open(archiveURL: archiveURL, workspaces: workspaces)
        try Data("edited".utf8).write(to: workspace.sourceURL.appendingPathComponent("app.js"))
        try workspace.discardChanges()
        XCTAssertEqual(try workspace.changes(), [])
        XCTAssertEqual(try String(contentsOf: workspace.sourceURL.appendingPathComponent("app.js"), encoding: .utf8), "console.log('hi')")

        try workspace.remove()
        XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.rootURL.path))
    }

    func testExistingFindsOnlyOpenWorkspaces() throws {
        XCTAssertNil(SourceWorkspace.existing(for: archiveURL, workspaces: workspaces))
        let (opened, _) = try SourceWorkspace.open(archiveURL: archiveURL, workspaces: workspaces)
        let found = try XCTUnwrap(SourceWorkspace.existing(for: archiveURL, workspaces: workspaces))
        XCTAssertEqual(found.sourceURL, opened.sourceURL)
        try opened.remove()
        XCTAssertNil(SourceWorkspace.existing(for: archiveURL, workspaces: workspaces))
    }

    func testTwoToolsShareOneWorkspace() throws {
        // e.g. the runtime's Edit Source window and `japp save` in Terminal.
        let (window, _) = try SourceWorkspace.open(archiveURL: archiveURL, workspaces: workspaces)
        let terminal = try XCTUnwrap(SourceWorkspace.existing(for: archiveURL, workspaces: workspaces))
        try Data("console.log('from terminal')".utf8).write(to: terminal.sourceURL.appendingPathComponent("app.js"))
        try terminal.save()

        // The other instance sees the saved state instead of reporting a conflict.
        XCTAssertFalse(window.archiveChangedOnDisk())
        XCTAssertEqual(try window.changes(), [])
        try Data("console.log('from window')".utf8).write(to: window.sourceURL.appendingPathComponent("app.js"))
        XCTAssertNoThrow(try window.save())
        XCTAssertEqual(try JAppPackage.load(from: archiveURL).resources.data(at: "app.js"), Data("console.log('from window')".utf8))
    }

    func testBackupsArePruned() throws {
        let (workspace, _) = try SourceWorkspace.open(archiveURL: archiveURL, workspaces: workspaces)
        for i in 0..<(SourceWorkspace.maxBackups + 3) {
            try Data("console.log(\(i))".utf8).write(to: workspace.sourceURL.appendingPathComponent("app.js"))
            try workspace.save()
        }
        let backups = try FileManager.default.contentsOfDirectory(atPath: workspace.backupsURL.path)
        XCTAssertEqual(backups.count, SourceWorkspace.maxBackups)
    }
}
