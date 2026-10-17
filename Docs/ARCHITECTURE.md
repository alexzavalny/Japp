# Architecture

JApp has three parts, all in one Swift package with no third-party dependencies:

```
Sources/
├── JAppKit/        core library (Foundation, zlib, CryptoKit; AppKit only for Finder icons/registry)
│   ├── Archive/          ZipArchive (reader), ZipWriter, Deflate/CRC32 (system zlib), ArchivePath rules
│   ├── Manifest.swift    manifest parsing + validation (forward-compatible)
│   ├── JAppPackage.swift loading an app from a .japp or a folder; ResourceProvider
│   ├── PackageValidator  full validation used by every tool
│   ├── Packager.swift    folder → .japp, safe extraction, atomic writes
│   ├── KeyValueStore     japp.storage persistence (JSON file + flock)
│   ├── SourceWorkspace   Edit Source: unpack, track changes, validate, repack, back up
│   ├── FinderIcon        custom Finder icons
│   └── InstanceRegistry  which runtime process hosts which app
├── JAppRuntime/    the macOS app "JApp Runtime" (AppKit + WebKit)
│   ├── AppDelegate, MainMenu, WelcomeWindowController
│   ├── ApplicationManager   hosting policy (process per app), open/reload/edit routing
│   ├── AppSession           one running app: window + WKWebView + bridge + storage
│   ├── WindowManager, WebViewFactory
│   ├── AppWebView, NativeFeel  native behaviour: drag regions, context menus, default CSS
│   ├── ArchiveSchemeHandler serves files from the archive (WKURLSchemeHandler)
│   ├── NativeBridge, BridgeModules, BridgeScript   window.japp
│   ├── IconManager, TrustPolicy, EditSessionController, EditorLocator
│   └── Automation           test hooks (japp snapshot, e2e tests)
└── japp/           the command-line tool
```

`Scripts/build.sh` compiles the two executables with SwiftPM and assembles
`build/JApp Runtime.app` (runtime in `Contents/MacOS`, CLI in `Contents/Helpers`,
`Info.plist` from `Resources/`, ad-hoc signature). No Xcode project is needed;
the Swift toolchain from Xcode or the Command Line Tools is enough.

## Key decisions

### 1. ZIP handling: a small, strict, in-house reader/writer on system zlib

`.japp` files are untrusted input, so the archive layer is where most safety
checks live. Rather than adding a dependency, JAppKit implements the small
subset of ZIP that `.japp` needs (single volume, Store/Deflate, no encryption,
no ZIP64) in ~400 lines, using the system `zlib` for DEFLATE and CRC-32. This
lets every rule be enforced up front, before any byte is decompressed:

* names validated (no absolute paths, `..`, backslashes, control characters…);
* symlinks, encrypted entries, unknown methods and duplicates rejected;
* declared sizes capped; decompression hard-limited to the declared size (bombs
  that lie about their size fail); overlapping entries rejected;
* local headers cross-checked against the central directory; CRC-32 verified on every read.

Interoperability is tested against Info-ZIP `zip`, `ditto` (Finder's *Compress*)
and Python's `zipfile` in both directions.

### 2. Resources are served from memory by a `WKURLSchemeHandler`

The archive is read into memory once (≤ 256 MB) and parsed; each request from
the web view is answered by `ArchiveSchemeHandler`, which decompresses the entry
on a background queue. Nothing is extracted to disk to run an app, so there are
no temporary files to clean up or tamper with, and an app being edited on disk
never changes underneath a running copy (reload picks up the new version).

Each app gets its own origin, `japp-resource://<app-id>/`. That gives:

* correct relative URLs, ES modules, workers, `fetch()` of bundled files, fonts
  and media (the handler supports HTTP range requests);
* same-origin isolation between apps, and a **secure context** in WebKit;
* real HTTP semantics: MIME types from a fixed table, 404 for missing files,
  `Cache-Control: no-store` (the archive is the cache; reload must show edits),
  `X-Content-Type-Options: nosniff`;
* a `Content-Security-Policy` header on every HTML response, which is how the
  `network` permission is enforced.

Temporary extraction was considered (simpler `loadFileURL` with
`allowingReadAccessTo:`) and rejected: it needs cleanup, leaves the files
writable by anything, and gives `file://` semantics, under which modules and
`fetch` behave differently.

### 3. One process per app (by default)

macOS gives one Dock tile, one menu-bar app name and one ⌘Q per *process*. If
every app ran inside one runtime process, they would share a Dock icon and
quitting one would quit all. So:

* the first app opened in a runtime process runs there;
* opening another app makes the runtime start a **new instance of itself**
  (`NSWorkspace.OpenConfiguration.createsNewApplicationInstance`, `--host <path>`);
* opening an app that already runs anywhere activates that process. A tiny
  registry (`~/Library/Application Support/JApp/Instances/<pid>.json`) maps
  processes to apps; requests between processes (activate, reload) use
  `DistributedNotificationCenter`.

The result: every app has its own Dock tile showing its own icon, its own ⌘Q,
its own entry in ⌘-Tab, and a crash in one app cannot take down another. Each
app additionally gets its own WebKit data store and web content process.

`AppSession` is self-contained, so one process can also host several apps
(`defaults write dev.japp.runtime JAppSingleProcess -bool YES`); the Dock tile
then follows the frontmost app. That mode is also used when the runtime runs
outside an `.app` bundle (development) and for automation.

### 4. App identity: what is and is not per app

| | Per app? | How |
|---|---|---|
| Window title, size, background | yes | manifest |
| Dock tile and its icon | yes | separate process + `NSApp.applicationIconImage` |
| Separate ⌘-Tab entry, ⌘Q, crash isolation | yes | separate process |
| Menus *About X*, *Hide X*, *Quit X*, About panel | yes | renamed at runtime |
| Bold app name in the menu bar | **no** — shows "JApp Runtime" | comes from the bundle's `CFBundleName` |
| Name under the Dock tile, in Activity Monitor and in notifications | **no** — "JApp Runtime" | bundle identity |
| Finder icon of the `.japp` file | yes, while the metadata survives | `NSWorkspace.setIcon` (§5) |

macOS has no public API to give one bundle several identities. Future options:

1. **Per-app shim bundles.** Generate `~/Library/Application Support/JApp/Shims/<id>.app`
   (Info.plist with the app's name, bundle id and icon; an executable that execs
   the runtime with `--host`), ad-hoc sign it with `codesign` (present on every Mac).
   This yields a true per-app name everywhere, including notifications and Spotlight,
   still without compiling the app. Cost: Launch Services churn and cleanup.
2. **Quick Look thumbnail extension** in the runtime that reads the icon out of
   the archive — Finder would then show each app's icon even on copies that lost
   their metadata. Requires an app-extension target (an Xcode build).

### 5. Finder icons

`NSWorkspace.setIcon` stores a custom icon as file metadata (resource fork +
Finder info). The runtime applies it when an app is opened or saved, and
records the icon's SHA-256 in an extended attribute so unchanged icons are not
rewritten on every launch. Copies that lost the metadata show the generic
`.japp` document icon until they are opened once. *File › Restore Finder Icon*
and `japp restore-icon` re-apply it on demand; `defaults write dev.japp.runtime
JAppSetFinderIcons -bool NO` turns the behaviour off.

### 6. Edit Source: workspace + explicit save

Editing unpacks the archive into a persistent workspace
(`~/Library/Application Support/JApp/Workspaces/<name>-<hash>/<App name>/`),
opens it in the user's editor, and shows a small control window. Saving is an
explicit action because external editors (which reuse processes and windows)
give no reliable "finished" signal.

Saving: validate the folder → build the archive in memory → load it back to
verify → copy the current file to `backups/` (last 5 kept) → write to a
same-volume temporary file → `FileManager.replaceItemAt` (atomic swap that keeps
the file's creation date and Finder tags). If anything fails, the original file
is untouched. A digest of the archive recorded at unpack/save time detects
changes made by other programs; the user then chooses to keep or replace them.

Entry points: Finder *Services › Edit JApp Source* (an `NSServices` entry in the
runtime's Info.plist — registering a file type alone adds no context-menu
command), *File › Edit Source…* in any app, `japp edit`, and the "Edit Source…"
button offered when an app fails to open. `japp save` shares the same workspace
(state lives in `session.json`), so the GUI and the terminal can be mixed.

A built-in text editor was considered; delegating to the user's real code
editor gives a better editing experience for less code. The control window
stays small: what changed, Save, Save & Run, Discard.

### 7. The bridge

`window.japp` is injected at document start in the page's content world. It
serialises each call to JSON and posts it to a `WKScriptMessageHandlerWithReply`,
which returns a Promise natively. Swift checks the sending frame (main frame,
own origin), the module/method and the manifest permission before doing
anything. Modules (`storage`, `dialog`, `notification`, `clipboard`, `http`, `menu`, `window`)
are small types behind one protocol, so adding a capability is one file plus a
`Permission` case. See [API.md](API.md).

### 8. Storage

`japp.storage` is a JSON file per app id, chosen over SQLite because it is
human-readable and inspectable (`japp storage <app>`), which fits "apps are
documents". Writes are atomic (temp file + rename) under an exclusive `flock`,
and each write re-reads the file if another process changed it, so two windows
or processes of the same app merge at key level rather than overwrite each
other. Limits: 5 MB per value, 50 MB per app — it is meant for app state, not bulk data.

### 9. Native feel: the runtime, not each app, removes the web tells

A web page in a window gives itself away in small ways: labels can be selected,
the cursor turns into an I-beam, images drag out, the whole page bounces, a
right-click offers Reload and Open Link, the menu bar has Reload and Zoom. The
runtime fixes these once for every app (`NativeFeel`, `AppWebView`):

* **Default stylesheet**, injected first and wrapped in `:where()` (zero
  specificity), so the app's CSS always wins: no selection outside text fields,
  arrow cursor, no image/link dragging, `overscroll-behavior: none`, system font.
* **Context menus.** A page script cancels the `contextmenu` event except on text
  fields, media and selected text (or with ⌥); `AppWebView.willOpenMenu` removes
  WebKit's browser items by identifier (`WKMenuItemIdentifierReload`,
  `…OpenLink`, `…DownloadImage`, …) and Inspect Element unless ⌥ is held or the
  app is in developer mode. An empty menu is closed as soon as it starts tracking.
  Apps build real menus with `japp.menu.popup` (an `NSMenu` popped up in the web view).
* **Menu bar.** Reload and page zoom live in a Develop menu shown only in
  developer mode; a hidden menu's key equivalents are inactive, so ⌘R stays free.
* **Window chrome.** `titleBarStyle: hidden / hiddenInset` use a full-size
  content view with a transparent, title-less title bar (`hiddenInset` adds an
  empty unified toolbar for the taller band). With full-size content AppKit
  delivers clicks in the title bar to the web view, so the page owns dragging:
  the page script reports the rectangles of `[data-japp-drag-region]` elements
  (minus the controls inside them) after every layout change, and
  `AppWebView.mouseDown` calls `NSWindow.performDrag(with:)` inside them — or
  performs the title-bar double-click action (`AppleActionOnDoubleClick`).
  Synchronous hit-testing against reported rectangles keeps dragging native
  (window tiling, Spaces) without waiting on JavaScript.
* **Window state.** Main/inactive, full screen, and the traffic lights' band
  height and inset are pushed to the page as `data-japp-*` attributes and
  `--japp-titlebar-*` variables, so CSS can dim inactive windows and lay out
  around the traffic lights.
* **Materials.** `material` puts an `NSVisualEffectView` behind a transparent web
  view. WebKit has no public API for a transparent web view; the runtime uses the
  `drawsBackground` key (SPI) only when the manifest asks for a material.

## Runtime defaults

All optional (`defaults write dev.japp.runtime <key> <value>`):

| Key | Default | Effect |
|---|---|---|
| `JAppSingleProcess` | NO | Host every app in one process. |
| `JAppSetFinderIcons` | YES | Apply app icons to `.japp` files in Finder. |
| `JAppEditor` | first installed | Bundle id of the editor for Edit Source (`finder` for Finder). |
| `JAppEditWindowInFront` | YES | Keep the Edit Source window above other windows. |
| `JAppDeveloperMode` | NO | Developer mode for every app: Develop menu (Reload, zoom) and Inspect Element without ⌥. |
| `JAppAutomationDir`, `JAppAutomationScript`, `JAppAutomationQuit` | — | Test hooks used by `japp snapshot` and `Scripts/e2e-test.sh`. |
| `JAppAutomationContextMenus`, `JAppAutomationProbePoints`, `JAppAutomationMenuChoice` | — | Test hooks: right-click and hit-test page points; pick an item in `japp.menu.popup` menus. |

Lifecycle events are logged to the unified log:
`log stream --predicate 'subsystem == "dev.japp.runtime"'`.
