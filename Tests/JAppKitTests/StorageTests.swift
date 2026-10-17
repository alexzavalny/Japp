import Foundation
import XCTest
@testable import JAppKit

final class StorageTests: XCTestCase {
    func testRoundTripsJSONValues() throws {
        let store = KeyValueStore(directory: try makeTemporaryDirectory(self))
        let values = [#""Alex""#, "42", "0.1", "-3.5e-7", "true", "false", "null", #"[1,"two",{"three":3}]"#,
                      #"{"nested":{"emoji":"🧮","list":[]}}"#, #""line\nbreak""#]
        for (index, json) in values.enumerated() { try store.set("k\(index)", json: json) }
        for (index, json) in values.enumerated() {
            let stored = try XCTUnwrap(try store.get("k\(index)"))
            let expected = try JSONSerialization.jsonObject(with: Data(json.utf8), options: .fragmentsAllowed)
            let actual = try JSONSerialization.jsonObject(with: Data(stored.utf8), options: .fragmentsAllowed)
            XCTAssertEqual(actual as? NSObject, expected as? NSObject, json)
        }
        XCTAssertEqual(try store.get("k1"), "42")
        // Doubles are written with 17 significant digits; JSON.parse yields the identical value.
        XCTAssertEqual(Double(try XCTUnwrap(try store.get("k2"))), 0.1)
        XCTAssertEqual(try store.get("k4"), "true")
        XCTAssertNil(try store.get("missing"))
    }

    func testPersistsAcrossInstances() throws {
        let dir = try makeTemporaryDirectory(self)
        try KeyValueStore(directory: dir).set("username", json: #""Alex""#)
        let reopened = KeyValueStore(directory: dir)
        XCTAssertEqual(try reopened.get("username"), #""Alex""#)
        XCTAssertEqual(try reopened.keys(), ["username"])

        try reopened.remove("username")
        XCTAssertNil(try KeyValueStore(directory: dir).get("username"))
    }

    func testConcurrentWritersDoNotLoseKeys() throws {
        let dir = try makeTemporaryDirectory(self)
        let a = KeyValueStore(directory: dir)
        let b = KeyValueStore(directory: dir)
        try a.set("one", json: "1")
        try b.set("two", json: "2")
        XCTAssertEqual(try a.get("two"), "2")
        try a.set("three", json: "3")
        XCTAssertEqual(try KeyValueStore(directory: dir).keys(), ["one", "three", "two"])

        try b.clear()
        XCTAssertEqual(try a.keys(), [])
    }

    func testRejectsInvalidInput() throws {
        let store = KeyValueStore(directory: try makeTemporaryDirectory(self))
        XCTAssertThrowsError(try store.set("", json: "1"))
        XCTAssertThrowsError(try store.set(String(repeating: "k", count: 600), json: "1"))
        XCTAssertThrowsError(try store.set("k", json: "{not json"))
        XCTAssertThrowsError(try store.set("k", json: "\"" + String(repeating: "x", count: KeyValueStore.maxValueSize) + "\""))
    }

    func testFileIsHumanReadable() throws {
        let dir = try makeTemporaryDirectory(self)
        let store = KeyValueStore(directory: dir)
        try store.set("theme", json: #""dark""#)
        let text = try String(contentsOf: store.fileURL, encoding: .utf8)
        XCTAssertTrue(text.contains(#""theme" : "dark""#), text)
    }

    func testDataDirectoryUsesAppID() {
        let url = JAppPaths.dataDirectory(forAppID: "Com.Example.Calculator")
        XCTAssertEqual(url.lastPathComponent, "com.example.calculator")
        XCTAssertEqual(url.deletingLastPathComponent().lastPathComponent, "Apps")
    }
}
