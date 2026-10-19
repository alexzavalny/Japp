import Foundation

/// The text of `japp help`.
///
/// The overview is written so that an AI coding agent (or a person) can make, change,
/// check and ship an app from it alone, without reading anything else: what a JApp is,
/// where things are on this Mac, step-by-step recipes, the rules, the manifest, the
/// `window.japp` API, how to verify work and the pitfalls. Each command has a page of
/// its own (`japp help <command>`), and the documentation that ships inside JApp
/// Runtime is available as topics (`japp help api`).
public enum HelpGuide {
    public struct Command: Sendable {
        public let name: String
        public let aliases: [String]
        public let synopsis: String
        public let summary: String
        public let details: String
    }

    /// A Markdown document from `Docs/`, shipped in `JApp Runtime.app/Contents/Resources/Docs`.
    public struct Topic: Sendable {
        public let name: String
        public let aliases: [String]
        public let file: String
        public let summary: String
    }

    /// What `japp help` reports about this Mac.
    public struct Environment {
        /// The running `japp` executable, symbolic links resolved.
        public var executable: String
        /// The first `japp` on `$PATH`, if any, as found there (not resolved).
        public var pathCommand: String?
        /// Whether `pathCommand` is this executable.
        public var pathCommandIsThis: Bool
        /// JApp Runtime.app, or the runtime binary of a development build.
        public var runtime: URL?
        public var runtimeVersion: String?
        public var docsDirectory: URL?
        public var examples: [URL]
        public var supportDirectory: URL

        public init(executable: String, pathCommand: String?, pathCommandIsThis: Bool, runtime: URL?,
                    runtimeVersion: String?, docsDirectory: URL?, examples: [URL], supportDirectory: URL) {
            self.executable = executable
            self.pathCommand = pathCommand
            self.pathCommandIsThis = pathCommandIsThis
            self.runtime = runtime
            self.runtimeVersion = runtimeVersion
            self.docsDirectory = docsDirectory
            self.examples = examples
            self.supportDirectory = supportDirectory
        }
    }

    public static func command(named name: String) -> Command? {
        commands.first { $0.name == name || $0.aliases.contains(name) }
    }

    public static func topic(named name: String) -> Topic? {
        topics.first { $0.name == name || $0.aliases.contains(name) || $0.file.lowercased() == name.lowercased() }
    }

    // MARK: - Short usage (`japp` with no arguments, mistakes)

    public static var usage: String {
        let width = commands.map(\.name.count).max() ?? 0
        let lines = commands.map { "  \($0.name.padding(toLength: width, withPad: " ", startingAt: 0))  \($0.summary)" }
        return """
            japp \(JAppVersion.runtime): make, check and ship JApps (Mac apps of HTML, CSS and JavaScript in one .japp file)

            USAGE
              japp <command> [arguments]

            COMMANDS
            \(lines.joined(separator: "\n"))

            Run `japp help` for the complete guide (recipes, rules, manifest, window.japp API),
            `japp help <command>` for one command's options and output.
            """
    }

    // MARK: - One command

    public static func page(for command: Command) -> String {
        var text = "japp \(command.name): \(command.summary)\n\nUSAGE\n"
        text += command.synopsis.split(separator: "\n").map { "  \($0)" }.joined(separator: "\n") + "\n"
        if !command.aliases.isEmpty {
            text += "\nALIASES\n  \(command.aliases.map { "japp \($0)" }.joined(separator: ", "))\n"
        }
        return text + "\n" + command.details.trimmingCharacters(in: .newlines)
    }

    // MARK: - The overview (`japp help`)

    public static func overview(_ environment: Environment) -> String {
        let width = commands.map(\.name.count).max() ?? 0
        let commandLines = commands.map { "  \($0.name.padding(toLength: width, withPad: " ", startingAt: 0))  \($0.summary)" }
        let helpLines = [("<command>", "options, output and examples of one command (= japp <command> --help)")]
            + topics.map { ($0.name, "\($0.summary) (\($0.file))") }
            + [("all", "this guide, every command page and every topic, in one go")]
        let helpWidth = helpLines.map(\.0.count).max() ?? 0
        let topicLines = helpLines.map { "  japp help \($0.0.padding(toLength: helpWidth, withPad: " ", startingAt: 0))  \($0.1)" }
        return """
            JApp \(JAppVersion.runtime): Mac apps made of plain HTML, CSS and JavaScript

            The complete guide to making, changing, checking and shipping JApps, written for AI coding
            agents and people alike: it is enough to work from without reading anything else.
            `japp help <command>` shows one command in depth; topics with the full documentation are
            listed at the end.

            WHAT A JAPP IS
              A .japp file is a ZIP archive: manifest.json at its root and web files next to it (HTML,
              CSS, JavaScript, images, fonts). JApp Runtime, a Mac app, runs it in a native window with
              WebKit (Safari's engine). Every app gets its own name in the menu bar, its own Dock icon
              and its own data, all keyed by the manifest's "id". The page gets `window.japp` for native
              features (storage, file panels, notifications, clipboard, HTTP without CORS, native menus,
              window control), each behind a permission that the manifest declares.
              There is no build step: no Node.js, npm, bundler, TypeScript or JSX. The files are what runs.

            THIS MAC
            \(environmentLines(environment).joined(separator: "\n"))

            RECIPES
              Make a new app
                japp new "Todo List" --id com.example.todo   # ./Todo List/: a working starter app + AGENTS.md
                # write manifest.json, index.html, style.css, app.js (add files and folders freely)
                japp validate "Todo List"                    # every error and warning; exit 1 if invalid
                japp snapshot "Todo List" -o /tmp/todo.png   # unattended run: screenshot + JSON report
                japp pack "Todo List" -o "Todo List.japp"    # the file to share or double-click

              Change an existing .japp (a workspace keeps edits until saved)
                japp edit App.japp --no-window               # prints "Source folder: <dir>"; edit there
                japp save App.japp                           # validate, repack atomically, back up the old one
                japp save App.japp --run --close             # ...also reload or launch it, delete the workspace
              or without a workspace:
                japp unpack App.japp ./App   # edit ./App, then:   japp pack ./App -o App.japp

              Already inside a source folder? If ../session.json exists, it is an Edit Source workspace:
              its "archivePath" is the .japp, saved with `japp save "<archivePath>" --run`. Never edit
              ../session.json or ../backups/. Otherwise it is a plain folder: pack it.

              Check behaviour, not only looks: --eval runs JavaScript in the page and reports the result
                JAPP_SUPPORT_DIR="$(mktemp -d)" japp snapshot "Todo List" -o /tmp/todo.png --eval '
                  document.querySelector("#name").value = "Ada";
                  document.querySelector("#hello").requestSubmit();
                  await new Promise(r => setTimeout(r, 200));
                  return document.querySelector("#greeting").textContent'
                # stdout: {"ok": true, "scriptResult": "Hello, Ada!", "console": [], ...}; exit 1 on JS errors
                # then look at /tmp/todo.png (JAPP_SUPPORT_DIR keeps the test out of the app's real data)

              Share it
                App.japp runs on any Mac with JApp Runtime (AirDrop, mail, a USB stick).
                japp export App.japp       # ./App.app: standalone, the runtime inside, for Macs without JApp

            COMMANDS (details: japp help <command>, or japp <command> --help)
            \(commandLines.joined(separator: "\n"))

            RULES
              1. Everything lives in the app folder; refer to files with relative URLs (style.css,
                 ./lib/chart.js). Nothing loads from the internet (CDNs, web fonts, remote scripts) unless
                 the manifest declares "network": copy libraries into the folder instead.
              2. Browser-ready JavaScript only: classic scripts or <script type="module"> (top-level await
                 works). No TypeScript, JSX or bare npm imports ("react"): nothing compiles or resolves them.
              3. Declare exactly the permissions the code uses: storage, dialog, notifications, clipboard,
                 network. A call without its permission rejects with error.code "PERMISSION_DENIED".
              4. Keep the "id" stable. Stored data, the WebKit data store and the app bundle belong to the
                 id; a new id starts from nothing. Change it only to make an independent copy.
              5. Keep data in japp.storage, never in the app's files (read-only while it runs).
              6. The window resizes: lay out with flexbox or grid, not fixed pixel positions.
              7. Protect unsaved documents: japp.window.setDocumentEdited(true) on every change, false after
                 saving, and japp.window.onBeforeClose(...) to offer Save / Don't Save / Cancel.
              8. One window per app. window.open() and links to http(s) pages open in the default browser.
                 No camera, microphone or geolocation; no file access except files the user picks.

            MANIFEST (manifest.json; full reference: japp help format)
              {
                "manifestVersion": 1,                  required; must be 1
                "id": "com.example.todo",              required; reverse-DNS: 2+ dot-separated parts of
                                                       letters, digits, hyphens; at most 128 characters
                "name": "Todo List",                   required; at most 100 characters; menu bar, Dock
                "version": "1.0.0",                    required; MAJOR[.MINOR[.PATCH[.BUILD]]][-pre][+build]
                "description": "…", "author": "…",     optional; shown in the About box
                "entry": "index.html",                 optional; default index.html (.html .htm .xhtml)
                "icon": "assets/icon.png",             optional; square PNG, 1024×1024
                "window": {                            optional; all fields optional
                  "width": 800, "height": 600,         initial content size in points (100–16384)
                  "minWidth": 400, "minHeight": 300,   at most the initial size (max*: at least it)
                  "resizable": true,
                  "titleBarStyle": "default",          default | transparent | hidden | hiddenInset
                  "material": "sidebar",               \(WindowOptions.Material.allCases.prefix(3).map(\.rawValue).joined(separator: " | ")) | … (japp help format)
                  "backgroundColor": "#1C1C1E"         #RGB #RRGGBB #RRGGBBAA; behind the page
                },
                "permissions": ["storage"]             \(Permission.allCases.map(\.rawValue).joined(separator: " "))
              }
              Unknown keys are ignored; unknown permissions and values are warnings, not errors.

            JAVASCRIPT API (window.japp, injected before the page's scripts; full reference: japp help api)
              Native calls return Promises. Failures reject with a japp.JAppError that has a `code`:
              PERMISSION_DENIED, BAD_ARGUMENTS, NOT_SUPPORTED, NOT_AUTHORIZED, NETWORK_ERROR,
              STORAGE_ERROR, FAILED, UNAVAILABLE (outside JApp Runtime; test `if (window.japp)`).

              [storage]  japp.storage.get(key, default = null) · set(key, value) · remove(key) · clear() ·
                         keys() → sorted keys. Any JSON value, types kept; kept across launches and edits.
                         Keys 1–512 characters, values up to 5 MB, 50 MB per app.
              [dialog]   japp.dialog.openFile({ accept: ["json", "image/*"], multiple, encoding, title })
                         → { name, size, type, text | base64 | dataURL } (array if multiple) or null.
                         encoding: "text" (default) | "base64" | "dataURL"; files up to 32 MB; no paths.
              [dialog]   japp.dialog.saveFile({ content, suggestedName, encoding: "text" | "base64",
                         accept, title }) → { name, size } or null
              [none]     japp.dialog.message({ title, message, buttons: ["Delete", "Cancel"],
                         style: "informational" | "warning" | "critical" }) → index of the button
              [notifications]  japp.notification.show({ title, subtitle, body, sound: true })
              [clipboard]      japp.clipboard.readText() → string or null · writeText(text)
              [network]  japp.http.fetch(url, { method, headers, body, timeout: 30, responseType:
                         "text" | "base64" }) → { ok, status, headers, json(), text(), arrayBuffer() }.
                         Not subject to CORS; body may be a string or any JSON value. HTTP errors resolve
                         with ok: false; connection failures reject with NETWORK_ERROR. Plain fetch() also
                         works with "network", under normal CORS rules.
              [none]     japp.menu.popup([{ id, label, symbol: "trash", shortcut: "cmd+d", enabled,
                         checked, submenu: [...] }, "-"], { x, y }) → id of the chosen item or null.
                         A real macOS menu; symbol is an SF Symbols name, "-" a separator.
              [none]     japp.window.setTitle(title) · minimize() · zoom() · close() ·
                         setDocumentEdited(boolean)
              [none]     japp.window.onBeforeClose(async ({ reason }) => true) → function that removes it.
                         reason: "close" | "quit" | "reload". Return true to proceed, anything else cancels.
              [none]     japp.app.{ id, name, version, description, permissions } · japp.hasPermission(name)
                         · japp.runtimeVersion
              The web platform works as in Safari: DOM, canvas, WebGL, Web Audio, workers, ES modules,
              crypto.subtle, localStorage, IndexedDB. alert/confirm/prompt show native sheets;
              <input type="file"> opens an Open panel; <a download> and blob downloads a Save panel.

            MAKE IT FEEL LIKE A MAC APP (more: japp help guide, "Making it feel native")
              * Already done by the runtime: system font, arrow cursor, unselectable labels, no image
                dragging, no rubber-band page, no browser context menus. Add data-selectable to text that
                people copy.
              * `:root { color-scheme: light dark; }` and system colours, which follow dark mode and the
                accent colour: -apple-system-label, -apple-system-secondary-label, -apple-system-separator,
                -apple-system-control-background, -apple-system-control-accent, AccentColor.
              * React when pressed (:active), not on :hover; no cursor: pointer. 13 px text, 24 px
                controls, 6–8 px corner radii.
              * Right-click menus come from japp.menu.popup, never from HTML imitations.
              * "titleBarStyle": "hidden" or "hiddenInset": the page fills the window. Mark the toolbar
                data-japp-drag-region, make it var(--japp-titlebar-height) tall and keep
                var(--japp-titlebar-inset) clear on the left for the window buttons.
                "material": "sidebar" shows through wherever the page has no background.
              * <html data-japp-window="inactive"> while the window is in the background: fade accents.
              * Handle the keys a Mac user expects: Return, Escape, ⌘F, ⌘, (⌘R, ⌘+ and ⌘− are free too).
              * Icon: a 1024×1024 PNG with a transparent background; the artwork is a rounded square of
                about 824×824 centred on it (corner radius about 185); one bold motif, no words.

            CHECKING YOUR WORK
              japp validate <app>     Static checks: manifest, files, entry page, icon, remote URLs
                                      without "network". Exit 1 on errors; warnings never fail.
              japp snapshot <app>     Runs the app unattended, waits for it to load, runs --eval/--script
                                      (if given), saves a PNG of the page, prints a JSON report, quits.
                                      Exit 1 if it did not load, the script threw, or anything was logged
                                      as a console error (uncaught exceptions, unhandled rejections and
                                      failed resource loads included).
              japp run <app> --console   The real window; console output streams to this terminal.
                                      Blocks until the app quits: start it in the background.
              Report (stdout of snapshot, JSON):
                ok, appId, name, version, windowTitle, windowVisible, contentSize {width, height},
                location, permissions, pid, console [{level: log|info|warn|error|debug, message}],
                scriptResult (the value the script returned), scriptError, native, identity, menus.
                If the app cannot load: {"ok": false, "file": …, "error": "…"}.

            PITFALLS
              * `japp snapshot` without -o writes a ~5 MB <Name>.png into the current folder.
              * snapshot and run use the app's real data: the japp.storage, localStorage and IndexedDB of
                its id. Prefix a snapshot with JAPP_SUPPORT_DIR="$(mktemp -d)" to give japp.storage a
                throwaway home; localStorage and IndexedDB are not redirected. Inspect or reset japp.storage
                with `japp storage <app> [--clear]`.
              * Scripts in snapshot must not wait on alert(), confirm(), prompt() or japp.dialog.*: they
                wait for a person, and the snapshot times out.
              * `japp run` opens a window on the user's screen and returns at once; `japp edit` without
                --no-window opens the user's code editor and an Edit Source window. Prefer snapshot and
                --no-window when no person is watching.
              * A .japp downloaded from the internet (com.apple.quarantine) asks for confirmation before
                it first runs; snapshot reports {"ok": false} with "quarantined" in the error.
              * An exported .app is sealed by its signature: never edit inside it; export again.
              * A Develop menu (Reload ⌘R, Inspect Element) exists only in developer mode: apps run from a
                folder, `japp run --console` or `--develop`, apps whose source is being edited.

            EXIT STATUS
              0 success · 1 failure (message on stderr, starting "japp:") · 64 unknown command

            MORE HELP
            \(topicLines.joined(separator: "\n"))
            """
    }

    static func environmentLines(_ environment: Environment) -> [String] {
        let indent = String(repeating: " ", count: 14)
        var lines: [String] = []
        if let command = environment.pathCommand, environment.pathCommandIsThis {
            lines.append("japp          \(JAppVersion.runtime): \(command) (on the PATH)")
            if command != environment.executable { lines.append("\(indent)→ \(environment.executable)") }
        } else {
            lines.append("japp          \(JAppVersion.runtime): \(environment.executable)")
            if let command = environment.pathCommand {
                lines.append("\(indent)`japp` on the PATH is another copy: \(command)")
            } else {
                lines.append("\(indent)not on the PATH: call it by this path, or install it with Scripts/install.sh")
            }
        }
        if let runtime = environment.runtime {
            lines.append("JApp Runtime  \(environment.runtimeVersion ?? "(development build)"): \(runtime.path)")
            if let version = environment.runtimeVersion, version != JAppVersion.runtime {
                lines.append("\(indent)differs from this japp \(JAppVersion.runtime): reinstall both with Scripts/install.sh")
            }
        } else {
            lines.append("JApp Runtime  NOT FOUND: run, snapshot, edit and export need it. Install it with")
            lines.append("\(indent)Scripts/install.sh from the JApp source, or set JAPP_RUNTIME to the .app")
        }
        if let docs = environment.docsDirectory {
            lines.append("Docs          \(docs.path)/ (japp help <topic>)")
        }
        if let first = environment.examples.first {
            lines.append("Examples      \(first.deletingLastPathComponent().path)/")
            lines.append("\(indent)\(environment.examples.map(\.lastPathComponent).joined(separator: ", ")): real apps to learn from")
            if first.pathExtension == JAppVersion.fileExtension {
                let example = environment.examples.last!.deletingPathExtension().lastPathComponent
                lines.append("\(indent)(japp unpack \"<that folder>/\(example).japp\" /tmp/\(example), then read the source)")
            }
        }
        lines.append("App data      \(environment.supportDirectory.path)/Apps/<id>/storage.json")
        lines.append("Workspaces    \(environment.supportDirectory.path)/Workspaces/ (japp edit)")
        return lines.map { "  " + $0 }
    }

    // MARK: - Topics

    public static let topics: [Topic] = [
        Topic(name: "api", aliases: ["javascript", "js", "window.japp"], file: "API.md",
              summary: "the window.japp JavaScript API and native look and feel"),
        Topic(name: "format", aliases: ["manifest", "permissions"], file: "FORMAT.md",
              summary: "the .japp format, every manifest field, permissions, data"),
        Topic(name: "guide", aliases: ["creating", "create", "design"], file: "CREATING_APPS.md",
              summary: "creating, editing and sharing apps; design guidelines"),
        Topic(name: "security", aliases: [], file: "SECURITY.md",
              summary: "what JApp enforces and what it does not"),
        Topic(name: "architecture", aliases: [], file: "ARCHITECTURE.md",
              summary: "how the runtime works, for people changing JApp itself"),
    ]

    // MARK: - Commands

    public static let commands: [Command] = [
        Command(
            name: "new", aliases: [],
            synopsis: "japp new <Name> [--id <com.example.name>] [--dir <parent folder>]",
            summary: "Create an app folder from the starter template",
            details: """
                Creates the folder <parent folder>/<Name> (default: the current folder) holding a small,
                working "Hello, World!" app, ready to be changed into the app you want:

                  manifest.json     id, name, version 1.0.0, a 480×360 resizable window, "storage"
                  index.html        the page (a greeting, a text field and a button)
                  style.css         system font and colours, light and dark mode
                  app.js            remembers the typed name with japp.storage
                  assets/icon.png   a placeholder icon: the app's initial on a coloured square
                  AGENTS.md         rules, workflow and API summary for AI coding agents; it is packed
                                    into the app, so whoever edits it next has it (delete it if unwanted)

                The id defaults to com.example.<name>. If an app on this Mac already uses that id (it has
                data or an app bundle here), a number is added (com.example.notes-2), because apps with
                the same id share their data. Pass --id with your own reverse-DNS id before sharing.
                Fails if the folder already exists.

                OUTPUT
                  Created <folder> (<id>), then the commands to run and pack it.

                EXAMPLES
                  japp new "Habit Tracker" --id com.alex.habits --dir ~/Projects
                  japp snapshot ~/Projects/"Habit Tracker" -o /tmp/habits.png
                """),
        Command(
            name: "validate", aliases: ["check"],
            synopsis: "japp validate <App.japp | folder>",
            summary: "Check an app for errors and warnings (exit 1 if invalid)",
            details: """
                Runs every check JApp Runtime makes before it opens an app: the archive rules (no absolute
                or .. paths, no symbolic links, no duplicates, size limits), every manifest field, that the
                entry page exists, that the icon is a readable, square image of a useful size, and that the
                entry page loads nothing from the internet without the "network" permission.

                OUTPUT
                  ✓ Todo.japp: Todo List 1.0.0 (com.example.todo) is valid — 6 files
                    warning: icon: “assets/icon.png” is only 256×256; use 1024×1024 …
                or
                  ✗ Todo.japp is not valid:
                    error: id: “nodots” is not a valid identifier; use reverse-DNS form …
                    error: window.width: must be between 100 and 16384 (got 50)
                Every problem is listed at once, as "error|warning: <field or file>: <message>".

                EXIT STATUS
                  0 valid (warnings never fail) · 1 invalid
                """),
        Command(
            name: "snapshot", aliases: ["screenshot"],
            synopsis: """
                japp snapshot <App.japp | folder> [-o|--output <shot.png>]
                              [--eval "<js>" | --script <test.js>] [--timeout <seconds>]
                """,
            summary: "Run an app unattended: screenshot + JSON report (+ run JS in the page)",
            details: """
                The way to test an app without a person: runs it in a process of its own, waits until the
                page has loaded, runs your JavaScript (if any), saves a PNG of the page and prints a JSON
                report, then quits. Its window may show for a moment; nothing stays open.

                OPTIONS
                  -o, --output <png>   Where to save the screenshot. Default: ./<Name>.png (about 5 MB, in
                                       the current folder), so always pass it, e.g. -o /tmp/shot.png.
                  --eval "<js>"        JavaScript run in the page as the body of an async function: use
                                       await, and `return` a JSON-serialisable value. It runs about 0.4 s
                                       after the page loads; the screenshot is taken after it finishes, so
                                       it can also put the app into the state you want to look at.
                  --script <file>      The same, from a file.
                  --timeout <s>        How long to wait for the whole run (default 30).

                OUTPUT
                  stdout: the report, as JSON with sorted keys:
                    ok              true once the app loaded
                    appId, name, version, permissions, pid
                    windowTitle, windowVisible, contentSize {width, height}, location (page URL)
                    console         [{"level": "log|info|warn|error|debug", "message": "…"}], including
                                    "Uncaught …", "Unhandled promise rejection: …", "Failed to load …"
                    scriptResult    what the script returned (null if nothing)
                    scriptError     the error if the script threw
                    native          window details: title bar, drag regions, menu bar, developer mode
                    identity        the bundle the app ran as: bundleIdentifier, localizedName, …
                    menus           the japp.menu.popup menus that were shown (then dismissed)
                  If the app could not load: {"ok": false, "file": "…", "error": "…"}.
                  stderr: "snapshot: <png path>".

                EXIT STATUS
                  0 · 1 if the app did not load, the script threw, any console error was logged, or the
                  run timed out

                SCRIPT TIPS
                  * Interact the way a person would: element.click(), field.value = "x" followed by
                    form.requestSubmit() or dispatchEvent(new Event("input", { bubbles: true })),
                    dispatchEvent(new KeyboardEvent("keydown", { key: "Enter", bubbles: true })).
                  * Give asynchronous work time: await new Promise(r => setTimeout(r, 200)), or poll until
                    an element appears.
                  * Return what you want to check: text, counts, computed styles, japp.storage values
                    (await japp.storage.get("todos")).
                  * Never wait on alert(), confirm(), prompt(), japp.dialog.* or file panels: they wait for
                    a person and the run times out.
                  * The app runs with its real data. JAPP_SUPPORT_DIR="$(mktemp -d)" gives japp.storage a
                    throwaway home; localStorage and IndexedDB still belong to the app's id.

                EXAMPLES
                  japp snapshot ./Todo -o /tmp/todo.png
                  japp snapshot Todo.japp -o /tmp/t.png --eval 'return document.title'
                  japp snapshot ./Todo -o /tmp/t.png --script tests/add-item.js > /tmp/report.json
                """),
        Command(
            name: "run", aliases: ["open"],
            synopsis: "japp run <App.japp | folder> [--console | --develop]",
            summary: "Open an app in a real window (--console streams its console here)",
            details: """
                Opens the app on the user's screen, as a double-click would. A .japp runs as an app of its
                own (its name in the menu bar, its icon in the Dock). A folder runs without packing, in
                developer mode (a Develop menu with Reload ⌘R and Inspect Element).

                OPTIONS
                  (none)      Returns at once; the app keeps running.
                  --console   Runs in this terminal: console.* output, uncaught errors and failed loads
                              print to stderr as "[Name] level: message". Blocks until the app quits (⌘Q)
                              or Ctrl-C; the exit status is the app's. Agents: start it in the background.
                  --develop   A separate process with the Develop menu and Inspect Element; returns at once.

                For automated checks use `japp snapshot`, which leaves no window behind. After
                `japp save --run`, a running app reloads in place instead of opening twice.

                EXAMPLES
                  japp run ./Todo --console
                  japp run Todo.japp
                """),
        Command(
            name: "pack", aliases: [],
            synopsis: "japp pack <folder> [-o|--output <App.japp>]",
            summary: "Package a folder as a .japp",
            details: """
                Validates the folder (as `japp validate` does) and zips it into a .japp, written atomically:
                an invalid app writes nothing and an existing file is replaced only on success. Leaves out
                hidden files (.git, .DS_Store, .vscode…), __MACOSX, Thumbs.db and backups ending in ~;
                refuses symbolic links. The output must end in .japp; default ./<folder name>.japp.

                OUTPUT
                  Packed Todo List 1.0.0 (com.example.todo)
                    6 files, 48 KB → /path/Todo List.japp
                  then any warnings. EXIT STATUS 1 if the app is invalid (the errors are listed).

                Without japp, any ZIP tool works if manifest.json ends up at the root:
                  cd Todo && zip -r -X ../Todo.japp . -x '.*'
                """),
        Command(
            name: "unpack", aliases: ["extract"],
            synopsis: "japp unpack <App.japp> [<folder>] [--force]",
            summary: "Extract a .japp into a folder",
            details: """
                Extracts the app's files into <folder> (default ./<App>) after checking every name, so an
                archive cannot write outside the folder. Refuses a folder that is not empty unless --force.
                Change the files, then repack: japp pack <folder> -o App.japp.
                Prefer `japp edit` for changing an app in place: it tracks changes and keeps backups.
                """),
        Command(
            name: "edit", aliases: [],
            synopsis: "japp edit <App.japp> [--no-window]",
            summary: "Unpack a .japp's source into a workspace for editing",
            details: """
                Unpacks the app into an editing workspace, or resumes the one that already exists for this
                file (unsaved edits survive quitting), and prints its source folder:
                  Source folder: \(JAppPaths.workspacesDirectory.path)/<name>-<hash>/<App Name>

                Workspace layout:
                  <name>-<hash>/session.json   names the .japp ("archivePath"); never edit it
                  <name>-<hash>/<App Name>/    the source: edit these files
                  <name>-<hash>/backups/       earlier versions of the .japp, newest last

                OPTIONS
                  --no-window   Only prepare the folder. Without it, JApp Runtime also opens the user's
                                code editor and an Edit Source window (Save / Save & Run): use --no-window
                                when no person is watching.

                Then: japp save App.japp [--run] [--close].
                """),
        Command(
            name: "save", aliases: [],
            synopsis: "japp save <App.japp> [--run] [--close] [--force]",
            summary: "Validate and repack an edited workspace into its .japp",
            details: """
                Validates the workspace started by `japp edit` (or by Edit Source in JApp Runtime) and
                repacks it into the .japp atomically. The replaced version goes to the workspace's backups/.
                Invalid source writes nothing: the problems are listed and the exit status is 1.

                OPTIONS
                  --run     Afterwards reload the app if it is running (in place), or launch it.
                  --close   Afterwards delete the workspace. Do this when the editing is finished.
                  --force   Save even though the .japp was changed by another program since editing began
                            (that version is kept in backups/).

                OUTPUT
                  Saved Todo.japp (modified: app.js, added: lib/chart.js), then any warnings.
                """),
        Command(
            name: "info", aliases: [],
            synopsis: "japp info <App.japp | folder> [--json]",
            summary: "Show manifest, files, data and bundle locations (--json)",
            details: """
                Prints the manifest summary, every file, where the app's japp.storage data lives, its app
                bundle (once it has run) and, for a .japp, its size, SHA-256 and whether it is quarantined.

                --json prints one object with the keys: id, name, version, description, entry, icon,
                permissions, files, window {width, height, resizable}, dataDirectory, appBundle,
                quarantined, sha256.
                """),
        Command(
            name: "storage", aliases: [],
            synopsis: "japp storage <App.japp | folder | app-id> [--clear]",
            summary: "Show or clear an app's japp.storage data",
            details: """
                Prints the path of the app's storage file and every key with its JSON value (long values
                are cut at 200 characters). The file is readable JSON:
                  \(JAppPaths.supportDirectory.path)/Apps/<id>/storage.json
                --clear deletes every key. localStorage and IndexedDB live in WebKit's data store
                (~/Library/WebKit/dev.japp.app.<id>/) and are not affected. Honours JAPP_SUPPORT_DIR.
                """),
        Command(
            name: "export", aliases: [],
            synopsis: """
                japp export <App.japp | folder> [-o|--output <Name.app | folder>]
                            [--sign <identity>] [--force]
                """,
            summary: "Make a standalone .app with the runtime inside",
            details: """
                Wraps the app, unchanged, in a standalone <Name>.app (about 2 MB) that carries JApp Runtime
                inside, for Macs that do not have it. A folder is packed first.

                OPTIONS
                  -o, --output   The .app to write, or an existing folder to write it into. Default:
                                 ./<Name>.app; `japp export .` inside an app folder writes next to the
                                 folder, never into it.
                  --sign <id>    A signing identity, e.g. "Developer ID Application: Name (TEAMID)".
                                 Default: ad hoc. Another Mac then blocks the first open until the user
                                 allows it in System Settings › Privacy & Security (Open Anyway); to share
                                 widely, sign with a Developer ID and notarize (xcrun notarytool submit …
                                 --wait, then xcrun stapler staple).
                  --force        Replace an existing .app.

                The exported app is sealed by its signature: never change files inside it; change the
                .japp and export again. It shares japp.storage with the .japp on the same Mac, but not
                localStorage or IndexedDB.
                """),
        Command(
            name: "bundles", aliases: ["bundle"],
            synopsis: "japp bundles [list | clean | remove <app-id | App.japp>]",
            summary: "List or remove the per-app bundles (menu-bar name, Dock icon)",
            details: """
                The first time an app runs, JApp Runtime makes a small app bundle for it, so the app has
                its own name, icon and bundle id (dev.japp.app.<id>) in the menu bar, Dock, ⌘-Tab and
                notifications:
                  \(JAppPaths.supportDirectory.path)/AppBundles/<id>/<Name>.app
                Its process is named after the app, not JAppRuntime.

                ACTIONS
                  list     (default) each bundle, whether it is running, and the .japp it last ran
                  clean    remove the bundles whose .japp no longer exists
                  remove   remove one (quit the app first); it is made again on the next run; data is kept
                """),
        Command(
            name: "restore-icon", aliases: [],
            synopsis: "japp restore-icon <App.japp>... [--remove]",
            summary: "Re-apply or remove the Finder icon of .japp files",
            details: """
                A .japp shows its app's icon in Finder through a custom icon attribute, which copying with
                some tools (git, zip, cloud drives) drops. This sets it again from the manifest's icon.
                --remove takes it off.
                """),
        Command(
            name: "help", aliases: ["--help", "-h"],
            synopsis: "japp help [<command> | <topic> | all]",
            summary: "The complete guide; japp help <command | topic> for more",
            details: """
                Without an argument: the complete guide. With a command: that command's page (the same
                as japp <command> --help). With a topic: a document that ships inside JApp Runtime
                (api, format, guide, security, architecture). `all` prints everything.
                """),
        Command(
            name: "version", aliases: ["--version", "-v"],
            synopsis: "japp version",
            summary: "Print the version of japp",
            details: "Prints \"japp <version>\". The runtime's version is in `japp help` under THIS MAC."),
    ]
}
