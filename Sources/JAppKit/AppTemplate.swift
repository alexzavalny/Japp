import AppKit
import Foundation

/// The "Hello, World!" app every new app starts from: JApp Runtime's
/// *File › New App…* writes it as a `.japp` file, `japp new` as a folder.
///
/// It is a complete, small app: a greeting, a text field and a button, styled
/// with the system colours and remembering the name in `japp.storage`, so each
/// of its three files shows one thing worth changing.
public enum AppTemplate {
    public static let defaultName = "My App"

    /// A usable app name: no control characters, at most 100 characters (the manifest's limit).
    public static func appName(from name: String) -> String {
        let scalars = name.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
        let cleaned = String(String.UnicodeScalarView(scalars)).trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? defaultName : String(cleaned.prefix(100)).trimmingCharacters(in: .whitespaces)
    }

    /// `com.example.<name>`, the name reduced to lower-case ASCII letters, digits and
    /// hyphens (accents dropped, other scripts transliterated). Two apps with one id
    /// would share their data and their app bundle, so while `isTaken` reports the id
    /// as used on this Mac a number is added: `com.example.notes-2`.
    public static func suggestedID(forName name: String, isTaken: (String) -> Bool = isInUse) -> String {
        let latin = name.applyingTransform(.toLatin, reverse: false)?.applyingTransform(.stripDiacritics, reverse: false) ?? name
        var slug = latin.lowercased().map { $0.isASCII && ($0.isLetter || $0.isNumber) ? String($0) : "-" }.joined()
            .split(separator: "-").joined(separator: "-")
        slug = String(slug.prefix(50))
        while slug.hasSuffix("-") { slug.removeLast() }
        let base = "com.example." + (slug.isEmpty ? "app" : slug)
        var id = base
        var number = 2
        while isTaken(id) && number < 1000 {
            id = "\(base)-\(number)"
            number += 1
        }
        return id
    }

    /// Whether an app with this id has run here (it has an app bundle or stored data).
    public static func isInUse(_ id: String) -> Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: AppBundle.directory(forAppID: id).path)
            || fm.fileExists(atPath: JAppPaths.dataDirectory(forAppID: id).path)
    }

    /// The app's files, keyed by app-relative path.
    public static func files(name: String, id: String) throws -> [String: Data] {
        let name = appName(from: name)
        return [
            "manifest.json": Data(try manifest(name: name, id: id).utf8),
            "index.html": Data(html(name: name).utf8),
            "style.css": Data(css.utf8),
            "app.js": Data(js.utf8),
            "assets/icon.png": try icon(letter: String(name.first ?? "A").uppercased()),
            "AGENTS.md": Data(agents(name: name).utf8),
        ]
    }

    /// Writes a new app named after the file (`Notes.japp` is "Notes") to `url`,
    /// replacing what is there. The archive is verified before it is written.
    @discardableResult
    public static func createArchive(at url: URL, name: String? = nil, id: String? = nil) throws -> Manifest {
        let name = appName(from: name ?? url.deletingPathExtension().lastPathComponent)
        let files = try files(name: name, id: id ?? suggestedID(forName: name))
        var writer = ZipWriter()
        for (path, data) in files.sorted(by: { $0.key < $1.key }) { try writer.addFile(path: path, contents: data) }
        let data = try writer.finish()
        let package = try JAppPackage.load(archiveData: data, url: url)
        try Packager.writeAtomically(data, to: url)
        return package.manifest
    }

    /// Writes a new app into `folder` (created if needed).
    @discardableResult
    public static func createFolder(at folder: URL, name: String? = nil, id: String? = nil) throws -> Manifest {
        let name = appName(from: name ?? folder.lastPathComponent)
        for (path, data) in try files(name: name, id: id ?? suggestedID(forName: name)) {
            let url = folder.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
        }
        return try JAppPackage.load(from: folder).manifest
    }

    // MARK: Files

    static func manifest(name: String, id: String) throws -> String {
        func json(_ string: String) throws -> String {
            String(decoding: try JSONSerialization.data(withJSONObject: string, options: [.fragmentsAllowed, .withoutEscapingSlashes]), as: UTF8.self)
        }
        return """
            {
              "manifestVersion": 1,
              "id": \(try json(id)),
              "name": \(try json(name)),
              "version": "1.0.0",
              "description": \(try json("\(name), a JApp.")),
              "entry": "index.html",
              "icon": "assets/icon.png",
              "window": { "width": 480, "height": 360, "minWidth": 360, "minHeight": 300, "resizable": true },
              "permissions": ["storage"]
            }

            """
    }

    static func html(name: String) -> String {
        let name = name.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
        return """
            <!doctype html>
            <html lang="en">
            <head>
              <meta charset="utf-8">
              <meta name="viewport" content="width=device-width, initial-scale=1">
              <title>\(name)</title>
              <link rel="stylesheet" href="style.css">
            </head>
            <body>
              <main>
                <img class="icon" src="assets/icon.png" alt="">
                <h1 id="greeting">Hello, World!</h1>
                <p>This is \(name). Change index.html, style.css and app.js, then click Save &amp; Run.</p>
                <form id="hello">
                  <input id="name" type="text" placeholder="Your name" autocomplete="off" spellcheck="false">
                  <button type="submit">Say Hello</button>
                </form>
              </main>
              <script src="app.js"></script>
            </body>
            </html>

            """
    }

    static let css = """
        /* JApp Runtime already gives the page the system font, the arrow cursor and
           unselectable labels; see Docs/API.md, "Native look and feel". */
        :root { color-scheme: light dark; }

        body {
          margin: 0;
          min-height: 100vh;
          display: grid;
          place-items: center;
          color: -apple-system-label;
        }

        main {
          display: flex;
          flex-direction: column;
          align-items: center;
          gap: 12px;
          padding: 24px;
          text-align: center;
        }

        .icon { width: 88px; height: 88px; }

        h1 { margin: 0; font-size: 30px; }

        p { margin: 0; max-width: 340px; line-height: 1.4; color: -apple-system-secondary-label; }

        form { display: flex; gap: 8px; margin-top: 8px; }

        input, button { font: inherit; padding: 5px 12px; border-radius: 6px; }

        input {
          width: 170px;
          border: 1px solid -apple-system-separator;
          background: -apple-system-control-background;
          color: inherit;
        }

        button { border: none; background: -apple-system-control-accent; color: white; }
        button:active { filter: brightness(0.85); }

        """

    static let js = """
        // window.japp is provided by JApp Runtime. See Docs/API.md.
        const greeting = document.getElementById("greeting");
        const nameField = document.getElementById("name");

        function greet(name) {
          greeting.textContent = name ? `Hello, ${name}!` : "Hello, World!";
        }

        document.getElementById("hello").addEventListener("submit", async (event) => {
          event.preventDefault();
          const name = nameField.value.trim();
          greet(name);
          await japp.storage.set("name", name);  // remembered the next time the app opens
        });

        japp.storage.get("name", "").then((name) => {
          nameField.value = name;
          greet(name);
        }).catch(console.error);

        """

    /// Instructions for AI coding agents (Codex, Cursor, Claude Code…) working in the
    /// source folder. They travel inside the `.japp`, so whoever edits the app next has them.
    static func agents(name: String) -> String {
        """
        # \(name) — notes for AI coding agents

        This folder is the source of **\(name)**, a JApp: a macOS app written in plain
        HTML, CSS and JavaScript plus a `manifest.json`, packed into one `.japp` file
        (a ZIP) and run by JApp Runtime in a native window with Safari's engine (WebKit).
        There is no build step, no Node.js, no npm and no bundler: these files are
        exactly what runs.

        ## Files

        | File | Purpose |
        |---|---|
        | `manifest.json` | Id, name, version, window and permissions (below). |
        | `index.html` | The page the window opens (`entry` in the manifest). |
        | `style.css`, `app.js` | The starter's style and code. Add files and folders freely. |
        | `assets/icon.png` | The app's Dock and Finder icon. It starts as a placeholder: see *Icon* below. |
        | `AGENTS.md` | This file. It is packed into the app too; keep it up to date or delete it. |

        ## Workflow

        * **Editing a `.japp` (Edit Source).** If `../session.json` exists, this folder is
          the editable copy of the `.japp` file named by its `archivePath`. Edits reach that
          file only when saved: the user clicks **Save & Run** in the Edit Source window, or
          you run `japp save "<archivePath>" --run` (validates, repacks, runs or reloads the
          app). Never edit `../session.json` or `../backups/`.
        * **A plain folder** (`japp new`): `japp pack . --output "../\(name).japp"` makes the
          `.japp` file.
        * **Check your work** after each change:
          * `japp validate .` lists every error and warning in the manifest and files.
          * `japp snapshot . -o /tmp/shot.png` runs the app without showing a window, saves
            a screenshot and prints a JSON report with the console output; the exit status
            is 1 on JavaScript errors. Add `--eval 'return document.title'` to run code in
            the page (an async function body) and get its result. Look at the screenshot.
          * `japp run . --console` opens the real window and streams the console to the
            terminal; it blocks until the app quits.
        * **Sharing.** The `.japp` runs on any Mac with JApp Runtime. For a Mac without it,
          `japp export` makes a standalone `\(name).app` with the runtime inside:
          `japp export "<archivePath>"` after saving (Edit Source), or `japp export .` in a
          plain folder (the app goes next to the folder, not into it). The exported app is
          sealed by its signature: export again after every change.
        * If `japp` is not on the PATH: `/Applications/JApp Runtime.app/Contents/Helpers/japp`.

        ## Rules

        1. **Everything lives in this folder.** Use relative paths (`style.css`,
           `./lib/chart.js`). Nothing loads from the internet (no CDNs, no web fonts) unless
           the manifest declares `"network"`; copy libraries into the folder instead.
        2. **Browser-ready JavaScript only**: plain scripts or ES modules
           (`<script type="module">`). No TypeScript, JSX or npm imports, since nothing compiles them.
        3. **Declare exactly the permissions the code uses**: `storage`, `dialog`,
           `notifications`, `clipboard`, `network`. Calls without them fail with
           `PERMISSION_DENIED`.
        4. **Keep the `id` stable.** The app's stored data and its app bundle are keyed by
           it; changing it starts the app from scratch.
        5. **Store data with `japp.storage`**, never in the app's files (they are read-only
           while the app runs).
        6. **Windows resize**: lay out with flexbox or grid, not fixed pixel positions.
        7. **Protect unsaved documents.** Call `japp.window.setDocumentEdited(true)` on edits
           and clear it after saving. Register `japp.window.onBeforeClose(async ({ reason }) => ...)`
           to offer Save / Don’t Save / Cancel for close, quit and reload; return `true` only
           when it is safe to proceed. A cancelled or failed save must keep the app open.

        ## manifest.json

        Required: `"manifestVersion": 1`, `"id"` (reverse-DNS: ASCII letters, digits and
        hyphens in two or more dot-separated parts), `"name"` (at most 100 characters; shown in the menu
        bar, Dock and ⌘-Tab), `"version"` (`"1.0.0"`). Optional: `"entry"` (default
        `index.html`), `"description"`, `"author"`, `"icon"`, `"permissions"`, and `"window"`:
        `width`, `height`, `minWidth`, `minHeight`, `resizable`, `titleBarStyle` (`"default"`,
        `"transparent"`, `"hidden"`, `"hiddenInset"`), `material` (e.g. `"sidebar"`) and
        `backgroundColor` (`"#1C1C1E"`).

        ## The `window.japp` API

        Native operations return Promises; failures reject with an error that has a `code`.
        `onBeforeClose(handler)` is synchronous and returns a function that removes the handler.

        | Call | Permission |
        |---|---|
        | `japp.storage.get(key, defaultValue)`, `.set(key, value)`, `.remove(key)`, `.clear()`, `.keys()`: any JSON value, kept across launches | `storage` |
        | `japp.dialog.openFile({ accept: ["json"], multiple, encoding })` → `{ name, size, type, text }` or `null` | `dialog` |
        | `japp.dialog.saveFile({ suggestedName, content, encoding })` → `{ name, size }` or `null` | `dialog` |
        | `japp.dialog.message({ title, message, buttons: ["OK", "Cancel"], style })` → index of the button | none |
        | `japp.notification.show({ title, body, sound: true })` | `notifications` |
        | `japp.clipboard.readText()`, `.writeText(text)` | `clipboard` |
        | `japp.http.fetch(url, { method, headers, body, timeout })` → `{ ok, status, headers, json(), text() }`; like `fetch()` but never blocked by CORS | `network` |
        | `japp.menu.popup([{ id, label, symbol, shortcut, enabled, checked, submenu }, "-"], { x, y })` → id of the chosen item or `null`; a native menu (`symbol` is an SF Symbols name) | none |
        | `japp.window.setTitle(title)`, `.minimize()`, `.zoom()`, `.close()` | none |
        | `japp.window.setDocumentEdited(boolean)`, `.onBeforeClose(handler)` | none |

        Also: `japp.app.id`, `.name`, `.version`, `.permissions`, `japp.hasPermission(name)`,
        `japp.runtimeVersion`. The usual web platform works too: `alert`/`confirm`/`prompt`
        (native sheets), `<input type="file">`, `<a download>`, canvas, workers,
        `localStorage`, IndexedDB.

        ## Make it feel like a Mac app

        * JApp Runtime already sets the system font, the arrow cursor, unselectable labels,
          no image dragging, no rubber-band scrolling and no browser context menus.
        * Use `color-scheme: light dark` and the system colours, which follow dark mode and
          the user's accent colour: `-apple-system-label`, `-apple-system-secondary-label`,
          `-apple-system-separator`, `-apple-system-control-background`,
          `-apple-system-control-accent`.
        * Controls react when pressed (`:active`), not on `:hover`; no `cursor: pointer`.
        * Right-click menus come from `japp.menu.popup`, not HTML imitations.
        * With a hidden title bar, mark the toolbar `data-japp-drag-region` so the window
          can be moved, make it `var(--japp-titlebar-height)` tall and keep
          `var(--japp-titlebar-inset)` clear on the left for the window buttons.
        * Add `data-selectable` to text people will want to copy.
        * Support the keyboard shortcuts a Mac user expects (⌘F, Return, Escape, ⌘,).

        ## Icon

        `assets/icon.png` starts as a placeholder: the app's initial on a coloured square.
        Once you know what the app does, **try to make it a real icon** if you have a tool
        that can make images (an image-generation tool or MCP server, or code that draws
        one, such as a script that renders SVG or Core Graphics to PNG):

        * A 1024×1024 PNG with a transparent background. The artwork is a macOS-style
          rounded square of about 824×824 centred on the canvas (100 px clear on every side,
          corner radius about 185 px), with the shape or scene drawn inside it.
        * One simple, bold motif that says what the app does and still reads at 16×16;
          no words or small details.
        * If the tool can only make a full-bleed square picture, put that picture inside
          the rounded square yourself (mask the corners, scale it to 824×824) instead of
          using it edge to edge.
        * Save it over `assets/icon.png` (or change `"icon"` in the manifest), run
          `japp validate .` (it catches unreadable, non-square and tiny images) and look at
          the result. Save & Run updates the app's Finder and Dock icons.

        No tool for images? Keep the placeholder and tell the user it is one.

        ## Reference

        The full documentation ships inside JApp Runtime, in
        `/Applications/JApp Runtime.app/Contents/Resources/Docs/`: `API.md` (`window.japp`),
        `FORMAT.md` (the manifest and the file format) and `CREATING_APPS.md` (guidelines).

        """
    }

    /// A simple generated icon: a coloured rounded square with the app's initial.
    static func icon(letter: String) throws -> Data {
        let size = 1024
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { throw JAppError.io("Could not create the app icon.") }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        let body = NSBezierPath(roundedRect: NSRect(x: 100, y: 100, width: 824, height: 824), xRadius: 185, yRadius: 185)
        let hue = CGFloat(abs(letter.unicodeScalars.first.map { Int($0.value) } ?? 0) % 360) / 360
        NSGradient(starting: NSColor(hue: hue, saturation: 0.55, brightness: 0.95, alpha: 1),
                   ending: NSColor(hue: hue, saturation: 0.75, brightness: 0.65, alpha: 1))!.draw(in: body, angle: -90)
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 480, weight: .bold), .foregroundColor: NSColor.white]
        let textSize = (letter as NSString).size(withAttributes: attributes)
        (letter as NSString).draw(at: NSPoint(x: 512 - textSize.width / 2, y: 512 - textSize.height / 2), withAttributes: attributes)
        NSGraphicsContext.restoreGraphicsState()
        guard let png = rep.representation(using: .png, properties: [:]) else { throw JAppError.io("Could not encode the app icon.") }
        return png
    }
}
