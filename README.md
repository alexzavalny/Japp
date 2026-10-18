# JApp

**Applications as documents.** A JApp is a single `.japp` file — a ZIP of HTML,
CSS, JavaScript and a `manifest.json`. Double-click it and it runs as a native
macOS app with its own window, title, icon and Dock tile. Right-click it and
choose **Edit JApp Source** to change it; save, and the new version runs.

```
DOUBLE-CLICK → RUN APPLICATION      EDIT SOURCE → MODIFY CODE      SAVE → RUN UPDATED APPLICATION
```

No Xcode, compiler, Node.js, npm or bundler is needed to make or run an app —
only the JApp Runtime, installed once. Apps run in the system's WebKit engine
(no Chromium), so the runtime is small and each app is a few kilobytes.

## Quick start

Requirements: macOS 14 or later (developed and tested on macOS 26.5, Apple
Silicon) and the Swift toolchain (Xcode or Command Line Tools) to build the runtime.

```sh
Scripts/build.sh          # builds build/JApp Runtime.app and build/Calculator.japp
Scripts/install.sh        # installs to /Applications, registers .japp, installs the `japp` command
open build/Calculator.japp
```

Then try the full loop:

1. Double-click `build/Calculator.japp` in Finder — the calculator opens.
2. Right-click it › *Services* › **Edit JApp Source** (or *File › Edit Source…* in the app).
3. In `style.css`, change `--key-operator: #ff9f0a;` to `--key-operator: #30d158;`.
4. Click **Save & Run** — the operator keys turn green. Reopen the file later: still green.

## Examples

* **[Calculator](Examples/Calculator)** — the reference app: plain HTML/CSS/JS, history in `japp.storage`, hidden title bar.
* **[Chess Results](Examples/ChessResults)** — a client for the
  [Easy Chess Results API](https://github.com/alexzavalny/ChessResultsApi): tournament
  search, standings, player results, player index, followed players with notifications.
  Uses `japp.http.fetch`, ES modules and a hash router; no build step. Styled as a Mac
  app: translucent sidebar, unified toolbar, native context menus.
* **[Paint](Examples/Paint)** — the tool set of Windows 98 Paint in a present-day Mac window:
  all sixteen tools (free-form select, eraser and colour eraser, flood fill, airbrush, curves,
  polygons…), the 28-colour box, flip/rotate, stretch/skew, canvas size, zoom with pixel grid,
  undo, and PNG/BMP/JPEG files through `japp.dialog`. Menus are real macOS menus
  (`japp.menu.popup` with SF Symbols and shortcuts); pixels are still drawn without anti-aliasing.

`Scripts/build.sh` packs every folder in `Examples/` into `build/<Name>.japp`.

## Make your own

Open JApp Runtime and choose **File › New App…** (⌘N; also a button in its
welcome window). Name the app and pick a folder: JApp writes `<Name>.japp` — a
"Hello, World!" app with a greeting, a text field and a button, plus an `AGENTS.md`
that tells AI coding agents how JApps work — and opens its source in your code
editor. Edit (or ask your agent to), click **Save & Run**, and it runs.

From Terminal:

```sh
japp new "Todo List"                         # the same starter app, as a folder
japp run "Todo List" --console               # run from the folder; JS console prints here
japp pack "Todo List" --output "Todo List.japp"
```

or write four files by hand and zip them — see **[Docs/CREATING_APPS.md](Docs/CREATING_APPS.md)**
(includes a checklist for AI coding assistants).

```json
{
  "manifestVersion": 1,
  "id": "com.example.calculator",
  "name": "Calculator",
  "version": "1.0.0",
  "entry": "index.html",
  "icon": "assets/icon.png",
  "window": { "width": 400, "height": 550, "minWidth": 300, "minHeight": 400, "resizable": true },
  "permissions": ["storage"]
}
```

```js
await japp.storage.set("username", "Alex");
const username = await japp.storage.get("username");
```

## The `japp` command

| Command | |
|---|---|
| `japp new <Name> [--id <id>]` | Create a starter app folder (the template of *File › New App…*) |
| `japp pack <folder> [--output App.japp]` | Validate and package (atomic) |
| `japp unpack <App.japp> [folder]` | Extract safely |
| `japp validate <App.japp\|folder>` | Report every error and warning |
| `japp info <App.japp> [--json]` | Manifest, files, data location |
| `japp run <App.japp\|folder> [--console] [--develop]` | Run; `--console` streams the app's JS console, `--develop` adds the Develop menu |
| `japp edit <App.japp> [--no-window]` | Open the source for editing |
| `japp save <App.japp> [--run] [--close]` | Save edited source back into the `.japp` |
| `japp snapshot <App.japp> [-o shot.png] [--eval js]` | Run headlessly; screenshot + JSON report |
| `japp restore-icon <App.japp>…` | Re-apply Finder icons |
| `japp storage <App.japp\|id> [--clear]` | Show or clear stored data |

## How it works

* **Format** — a plain ZIP with `manifest.json` at the root ([FORMAT.md](Docs/FORMAT.md)).
* **Runtime** — Swift/AppKit app hosting a `WKWebView` per app. Files are served
  straight from the archive in memory through a `WKURLSchemeHandler` at
  `japp-resource://<app-id>/`; nothing is extracted to run an app.
* **A real app per app** — JApp Runtime generates a tiny signed bundle for each app
  (`~/Library/Application Support/JApp/AppBundles`), so every app runs as its own
  process with its own name in the menu bar, Dock, ⌘-Tab and notifications, its
  own icon, ⌘Q and crash isolation. The bundle holds only a 53 KB launcher that
  loads the runtime from JApp Runtime.app; you can keep it in the Dock.
* **Native API** — `window.japp` (storage, file dialogs, notifications, clipboard,
  CORS-free HTTP, native context menus, window), Promise-based, permission-checked in Swift ([API.md](Docs/API.md)).
* **Native feel** — no text selection on labels, arrow cursor, no bouncing page,
  no browser context menus or Reload in the menu bar; hidden title bars with
  drag regions, window materials (translucent sidebars), window state for CSS
  ([API.md › Native look and feel](Docs/API.md#native-look-and-feel)).
* **Data** — kept outside the archive in `~/Library/Application Support/JApp/Apps/<id>/`, keyed by app id.
* **Icons** — the icon inside the archive becomes the Dock icon and, via
  `NSWorkspace.setIcon`, the file's Finder icon.
* **Editing** — unpacks into a workspace, opens your code editor, and saves back
  atomically with validation and backups ([ARCHITECTURE.md](Docs/ARCHITECTURE.md)).
* **Security** — strict ZIP validation (ZIP Slip, bombs, symlinks), per-app
  origin and data store, CSP-enforced network permission, origin-checked bridge,
  confirmation for downloaded apps ([SECURITY.md](Docs/SECURITY.md)).

## Status of the MVP

| Acceptance criterion | Status |
|---|---|
| Runtime builds and installs | ✅ `Scripts/build.sh`, `Scripts/install.sh` |
| macOS recognises `.japp` | ✅ UTI `dev.japp.app`, default app verified via Launch Services |
| Double-click launches Calculator | ✅ via `open` (the Launch Services path Finder uses); physical double-click not automated |
| Native window, own title | ✅ verified (title, size) |
| HTML/CSS/JS run correctly | ✅ e2e tests drive the UI |
| Custom icon | ✅ Finder icon verified; Dock icon set via API (Dock not observed) — see limitations |
| Persistent storage from JS | ✅ survives restarts (tested) |
| Open and modify source | ✅ Services item, menu, CLI; editor hand-off tested with Finder |
| Save back into the `.japp` | ✅ validated, atomic, backed up (tested) |
| Relaunch shows changes | ✅ tested (relaunch and in-place reload) |
| New apps need no runtime rebuild | ✅ *File › New App…*, `japp new` / zip |
| Instructions for new apps | ✅ [CREATING_APPS.md](Docs/CREATING_APPS.md) |

What was tested automatically, by hand, and what still needs a person at the
Mac: **[Docs/TESTING.md](Docs/TESTING.md)**.

### Known limitations

* Opening a `.japp` passes through JApp Runtime (hidden, ~0.6 s) before the app's
  own bundle starts; see [ARCHITECTURE.md](Docs/ARCHITECTURE.md#3-one-process-per-app-each-in-a-bundle-of-its-own).
  An app renamed while it runs keeps its old name in the menu bar until it is reopened.
* Finder icons are file metadata and are lost when a file is emailed or
  downloaded; the runtime restores them when the app is opened.
* The runtime is ad-hoc signed and not sandboxed; see [SECURITY.md](Docs/SECURITY.md#known-limitations).

## Repository layout

```
Package.swift            SwiftPM package (no dependencies)
Sources/JAppKit/         core: ZIP, manifest, packaging, storage, workspaces
Sources/JAppRuntime/     the macOS app (AppKit + WebKit)
Sources/japp/            the command-line tool
Tests/JAppKitTests/      unit tests (swift test)
Tests/E2E/               end-to-end test script and helpers
Examples/Calculator/     the reference app (source of Calculator.japp)
Resources/               Info.plist, runtime and document icons
Scripts/                 build.sh, install.sh, e2e-test.sh, make-icons.swift
Docs/                    FORMAT, API, CREATING_APPS, ARCHITECTURE, SECURITY, TESTING
```

Uninstall: delete `/Applications/JApp Runtime.app`, `/usr/local/bin/japp` and
`~/Library/Application Support/JApp`.
