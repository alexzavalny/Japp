import Foundation
import XCTest
@testable import JAppKit

/// `japp help` is what agents read first, so it must describe the CLI that exists.
/// These tests compare it with the sources of `japp` and with the docs it points to.
final class HelpGuideTests: XCTestCase {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    func environment(pathCommand: String? = "/usr/local/bin/japp", pathCommandIsThis: Bool = true,
                     runtime: URL? = URL(fileURLWithPath: "/Applications/JApp Runtime.app"),
                     runtimeVersion: String? = JAppVersion.runtime) -> HelpGuide.Environment {
        let app = URL(fileURLWithPath: "/Applications/JApp Runtime.app")
        return HelpGuide.Environment(
            executable: app.appendingPathComponent("Contents/Helpers/japp").path,
            pathCommand: pathCommand, pathCommandIsThis: pathCommandIsThis,
            runtime: runtime, runtimeVersion: runtimeVersion,
            docsDirectory: app.appendingPathComponent("Contents/Resources/Docs"),
            examples: ["Calculator", "ChessResults", "Paint"].map { app.appendingPathComponent("Contents/Resources/Examples/\($0).japp") },
            supportDirectory: URL(fileURLWithPath: "/Users/someone/Library/Application Support/JApp"))
    }

    /// The `case "…", "…": try cmdX(rest)` lines of the dispatch in Sources/japp/main.swift.
    func dispatchedCommands() throws -> [[String]] {
        let source = try String(contentsOf: root.appendingPathComponent("Sources/japp/main.swift"), encoding: .utf8)
        let dispatch = try XCTUnwrap(source.range(of: "switch command {")).upperBound
        return source[dispatch...].split(separator: "\n").compactMap { line -> [String]? in
            let line = line.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("case \""), let colon = line.firstIndex(of: ":") else { return nil }
            return line[line.index(line.startIndex, offsetBy: 5)..<colon]
                .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"")) }
        }
    }

    func testEveryCommandOfTheCLIIsDocumentedWithItsAliases() throws {
        let dispatched = try dispatchedCommands()
        XCTAssertGreaterThan(dispatched.count, 10)
        for names in dispatched {
            let command = try XCTUnwrap(HelpGuide.command(named: names[0]), "japp \(names[0]) has no help page")
            XCTAssertEqual(Set([command.name] + command.aliases), Set(names), "names of japp \(command.name)")
        }
        XCTAssertEqual(Set(HelpGuide.commands.map(\.name)), Set(dispatched.map { $0[0] }), "help documents only real commands")
    }

    /// Every option a command parses (`valueOptions:` and `flags.contains`) is in its synopsis.
    func testEveryOptionOfTheCLIIsInItsCommandsSynopsis() throws {
        let source = try String(contentsOf: root.appendingPathComponent("Sources/japp/main.swift"), encoding: .utf8)
        let functions = source.components(separatedBy: "\nfunc cmd").dropFirst()
        var checked = 0
        for function in functions {
            let camel = String(function.prefix { $0.isLetter })
            let name = camel.enumerated().map { $0.offset > 0 && $0.element.isUppercase ? "-\($0.element)" : "\($0.element)" }
                .joined().lowercased()  // RestoreIcon → restore-icon
            guard name != "help" else { continue }
            let command = try XCTUnwrap(HelpGuide.command(named: name), "cmd\(camel) has no help page")
            let body = function.components(separatedBy: "\n}\n")[0]
            var options: [String] = []
            for pattern in [#"flags\.contains\("([a-z-]+)"\)"#, #"options\["([a-z-]+)"\]"#] {
                let regex = try NSRegularExpression(pattern: pattern)
                for match in regex.matches(in: body, range: NSRange(body.startIndex..., in: body)) {
                    options.append(String(body[Range(match.range(at: 1), in: body)!]))
                }
            }
            for option in options {
                XCTAssertTrue(command.synopsis.contains("--\(option)"), "japp \(name) --\(option) is not in its synopsis")
                checked += 1
            }
        }
        XCTAssertGreaterThan(checked, 15)
    }

    func testTopicsAreShippedDocs() throws {
        for topic in HelpGuide.topics {
            let file = root.appendingPathComponent("Docs").appendingPathComponent(topic.file)
            XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), "\(topic.file) (japp help \(topic.name))")
            XCTAssertEqual(HelpGuide.topic(named: topic.name)?.file, topic.file)
        }
        XCTAssertEqual(HelpGuide.topic(named: "manifest")?.file, "FORMAT.md")
        XCTAssertEqual(HelpGuide.topic(named: "api.md")?.file, "API.md")
        XCTAssertNil(HelpGuide.topic(named: "run"), "commands and topics do not overlap")
        for command in HelpGuide.commands {
            XCTAssertNil(HelpGuide.topic(named: command.name), "\(command.name) is both a command and a topic")
        }
    }

    func testOverviewCoversWhatAnAgentNeeds() {
        let text = HelpGuide.overview(environment())
        for section in ["WHAT A JAPP IS", "THIS MAC", "RECIPES", "COMMANDS", "RULES", "MANIFEST", "JAVASCRIPT API",
                        "MAKE IT FEEL LIKE A MAC APP", "CHECKING YOUR WORK", "PITFALLS", "EXIT STATUS", "MORE HELP"] {
            XCTAssertTrue(text.contains("\n\(section)"), "section \(section)")
        }
        for permission in Permission.allCases {
            XCTAssertTrue(text.contains("[\(permission.rawValue)]"), "the API lists what \(permission.rawValue) grants")
        }
        for style in ["default", "transparent", "hidden", "hiddenInset"] {
            XCTAssertNotNil(WindowOptions.TitleBarStyle(rawValue: style))
            XCTAssertTrue(text.contains(style))
        }
        for command in HelpGuide.commands {
            XCTAssertTrue(text.contains("\n  \(command.name) "), "\(command.name) is listed")
        }
        for topic in HelpGuide.topics {
            XCTAssertTrue(text.contains("japp help \(topic.name) "), "topic \(topic.name) is listed")
        }
    }

    /// The --eval recipe drives the app `japp new` makes, so it must use that app's element ids.
    func testEvalRecipeMatchesTheStarterApp() {
        let text = HelpGuide.overview(environment())
        let html = AppTemplate.html(name: "Todo List")
        for id in ["name", "hello", "greeting"] {
            XCTAssertTrue(text.contains("querySelector(\"#\(id)\")"))
            XCTAssertTrue(html.contains("id=\"\(id)\""), "the starter app has #\(id)")
        }
        XCTAssertTrue(AppTemplate.js.contains("Hello, ${name}!"), "the recipe's expected result: \"Hello, Ada!\"")
    }

    func testEnvironmentLines() {
        var text = HelpGuide.overview(environment())
        XCTAssertTrue(text.contains("/usr/local/bin/japp (on the PATH)\n                → /Applications/JApp Runtime.app/Contents/Helpers/japp\n"))
        XCTAssertTrue(text.contains("JApp Runtime  \(JAppVersion.runtime): /Applications/JApp Runtime.app\n"))
        XCTAssertTrue(text.contains("Calculator.japp, ChessResults.japp, Paint.japp: real apps"))
        XCTAssertTrue(text.contains("japp unpack \"<that folder>/Paint.japp\" /tmp/Paint"))
        XCTAssertTrue(text.contains("/Users/someone/Library/Application Support/JApp/Apps/<id>/storage.json"))

        text = HelpGuide.overview(environment(pathCommand: nil))
        XCTAssertTrue(text.contains("not on the PATH"))
        text = HelpGuide.overview(environment(pathCommand: "/opt/bin/japp", pathCommandIsThis: false))
        XCTAssertTrue(text.contains("another copy: /opt/bin/japp"))
        text = HelpGuide.overview(environment(runtime: nil, runtimeVersion: nil))
        XCTAssertTrue(text.contains("JApp Runtime  NOT FOUND"))
        text = HelpGuide.overview(environment(runtimeVersion: "0.0.1"))
        XCTAssertTrue(text.contains("differs from this japp"))
    }

    /// Readable in an 100-column terminal, and nothing an agent would mistake for a tab stop.
    func testEveryLineFitsInAHundredColumns() {
        let pages = [HelpGuide.overview(environment()), HelpGuide.usage] + HelpGuide.commands.map(HelpGuide.page)
        for page in pages {
            for line in page.split(separator: "\n", omittingEmptySubsequences: false) {
                XCTAssertLessThanOrEqual(line.count, 100, "too long: \(line)")
                XCTAssertFalse(line.contains("\t"))
                XCTAssertFalse(line.hasSuffix(" "), "trailing space: \(line)")
            }
        }
    }

    func testCommandPage() throws {
        let page = HelpGuide.page(for: try XCTUnwrap(HelpGuide.command(named: "screenshot")))
        XCTAssertTrue(page.hasPrefix("japp snapshot: "))
        XCTAssertTrue(page.contains("\nUSAGE\n  japp snapshot <App.japp | folder>"))
        XCTAssertTrue(page.contains("\nALIASES\n  japp screenshot\n"))
        XCTAssertTrue(page.contains("\nEXIT STATUS\n"))
        XCTAssertFalse(page.hasSuffix("\n"))
    }
}
