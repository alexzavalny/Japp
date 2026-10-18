# Architecture

JApp has four parts, all in one Swift package with no third-party dependencies:

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
│   ├── AppTemplate       the "Hello, World!" app (and its AGENTS.md) of File › New App… and `japp new`
│   ├── AppBundle, ICNS   per-app bundles: generate, sign, update in place, launch record
│   ├── FinderIcon        custom Finder icons
│   └── InstanceRegistry  which process hosts which app
├── JAppLauncher/   main.c: the main executable of JApp Runtime.app and of every app bundle
├── JAppRuntime/    JAppRuntimeCore.dylib: the runtime itself (AppKit + WebKit)
│   ├── RuntimeMain, ProcessIdentity   entry point; JApp Runtime vs. an app's bundle
│   ├── AppDelegate, MainMenu, WelcomeWindowController
│   ├── ApplicationManager   hosting policy (app bundles), open/reload/edit routing
│   ├── AppSession           one running app: window + WKWebView + bridge + storage
│   ├── WindowManager, WebViewFactory
│   ├── AppWebView, NativeFeel  native behaviour: drag regions, context menus, default CSS
│   ├── ArchiveSchemeHandler serves files from the archive (WKURLSchemeHandler)
│   ├── NativeBridge, BridgeModules, BridgeScript   window.japp
│   ├── IconManager, TrustPolicy, EditSessionController, EditorLocator
│   └── Automation           test hooks (japp snapshot, e2e tests)
└── japp/           the command-line tool
```

`Scripts/build.sh` builds the library and the two executables with SwiftPM and
assembles `build/JApp Runtime.app` (launcher in `Contents/MacOS`, runtime library in
`Contents/Frameworks`, CLI in `Contents/Helpers`, `Info.plist` from `Resources/`,
ad-hoc signature with the hardened runtime). No Xcode project is needed; the
Swift toolchain from Xcode or the Command Line Tools is enough.

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

### 3. One process per app, each in a bundle of its own

macOS gives one Dock tile, one menu-bar app name and one ⌘Q per *process*, and
takes the name it shows — in bold in the menu bar, under the Dock tile, in ⌘-Tab,
in notifications, in Activity Monitor — from the *bundle* the process was started
from. One bundle has one identity, and there is no public API to change it at run
time. So every app runs in a process of its own, started from a bundle of its own:

```
~/Library/Application Support/JApp/AppBundles/<app-id>/
  Chess Results.app/Contents/Info.plist                name, version, icon, dev.japp.app.<app-id>
  Chess Results.app/Contents/MacOS/Chess Results       a copy of JApp Runtime's launcher (53 KB)
  Chess Results.app/Contents/Resources/AppIcon.icns    made from the manifest icon
  launch.json                                          the .japp it last ran (path + bookmark)
```

**The launcher.** `Sources/JAppLauncher/main.c` is the main executable of JApp
Runtime.app and, copied, of every app bundle. It finds `JAppRuntimeCore.dylib`
(next to itself in JApp Runtime.app; through `JAppRuntimePath` in an app bundle's
Info.plist; or through Launch Services if JApp Runtime moved), loads it and calls
`JAppRuntimeMain`. So an app bundle contains no runtime code and no app code: it
is only an identity. Runtime updates apply to every app at once, and a bundle
takes about 0.5 MB, almost all of it the icon.

**Opening a `.japp`** (double-click, `open`, `japp run`):

1. Launch Services starts JApp Runtime, the handler of `.japp` files. Its
   Info.plist declares `LSUIElement`, so it starts with no Dock tile or menu bar.
2. It validates the file and, for a downloaded file, asks for confirmation (§ Security).
3. `AppBundle.prepare` reuses the app's bundle, or builds it if anything it was
   made from changed: name, version, icon digest, launcher digest, runtime
   location, bundle format. Building happens in a staging folder; the bundle is
   ad-hoc signed with `/usr/bin/codesign` (same hardened runtime and entitlements
   as JApp Runtime.app); then an existing bundle keeps its folder — renamed if the
   app was renamed — and only has its `Contents` swapped, so a Dock item that
   points at it keeps working. A bundle whose app is running is never touched; it
   is updated on the next launch.
4. It records the file in `launch.json`, starts the bundle with
   `--host <path>` (`NSWorkspace.openApplication`, yielding activation to it) and
   quits, having shown nothing.

If any of this fails, the runtime runs the app itself (§4 lists what is then
shared). Measured on Apple silicon: ~0.6 s from `open` to the app's own process,
including building and signing the bundle the first time.

**An app bundle** runs exactly one app: the one it was started with, or — when
started on its own from the Dock, Spotlight or Finder — the file in
`launch.json` (found again through its bookmark if it moved; otherwise the app
asks the user to locate it). A file with a different app id (or one whose id was
edited) is handed back to JApp Runtime with `NSWorkspace.open(_:withApplicationAt:)`.
Its menus leave out the runtime's own commands (About JApp Runtime, Install
Command-Line Tool, Open…, the Help item).

**Already running?** A tiny registry (`~/Library/Application Support/JApp/Instances/<pid>.json`)
maps processes to the files they host; opening a file that is running anywhere
activates that process instead, and requests between processes (activate, reload
after Save & Run) use `DistributedNotificationCenter`. Two *files* with the same
app id run as two instances of the same bundle.

**Without app bundles** (`defaults write dev.japp.runtime JAppAppBundles -bool NO`),
the first app runs in the JApp Runtime process and each further app in a new
runtime instance (`createsNewApplicationInstance`, `--host <path>`): still one
process, Dock tile and ⌘Q per app, but with the runtime's name. `AppSession` is
self-contained, so one process can also host several apps (`JAppSingleProcess`);
the Dock tile then follows the frontmost app. That mode is also used by
`japp run --console` (the console goes to the terminal), by `japp snapshot` and
the tests, and when the runtime runs from a build folder instead of an `.app`.

### 4. App identity: what is and is not per app

| | Per app? | How |
|---|---|---|
| Name in the menu bar (bold), under the Dock tile, in ⌘-Tab, Activity Monitor, Force Quit | yes | the app bundle's `CFBundleName` and file name |
| Dock tile icon, Finder/Spotlight icon of the app bundle | yes | `AppIcon.icns` in the bundle (and `NSApp.applicationIconImage`) |
| Notifications: sender name, icon, permission in System Settings | yes | the bundle id `dev.japp.app.<app-id>` |
| Separate process, ⌘Q, crash isolation | yes | one process per app |
| Menus *About X*, *Hide X*, *Quit X*, About panel | yes | renamed at run time |
| Window positions, Open Recent | yes | the bundle's own preferences domain |
| Runtime settings (`defaults write dev.japp.runtime …`) | shared | read from JApp Runtime's domain in every process |
| `localStorage`, IndexedDB, cookies | yes | WebKit data store per app id, in `~/Library/WebKit/dev.japp.app.<app-id>/` |
| `japp.storage` | yes | `Apps/<app-id>/storage.json`, independent of the bundle |
| Finder icon of the `.japp` file | yes, while the metadata survives | `NSWorkspace.setIcon` (§5) |

The bundle id is `dev.japp.app.` + the app id, so a `.japp` cannot take over
another program's identity: an app with id `com.apple.finder` becomes
`dev.japp.app.com.apple.finder`. The *display* name is whatever the manifest says
(an app can call itself "Finder"); the About panel always shows the app id and
"Runs on JApp Runtime". Moving to app bundles changes the WebKit container, so
`localStorage` written by a version before 0.3 starts empty; `japp.storage` is unaffected.

Removing bundles: `japp bundles` lists them with the file each runs,
`japp bundles clean` deletes those whose file is gone, `japp bundles remove <id>`
deletes one (it is rebuilt the next time the app runs). Data is never deleted with a bundle.

A **Quick Look thumbnail extension** in the runtime that reads the icon out of
the archive would show each app's icon even on `.japp` copies that lost their
Finder metadata; it needs an app-extension target (an Xcode build).

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
command), *File › Edit Source…* in any app, `japp edit`, the "Edit Source…"
button offered when an app fails to open, and JApp Runtime's *File › New App…*,
which asks for a name in a Save panel, writes `AppTemplate`'s app there (named
after the file, with an id no app on this Mac uses yet) and opens it for editing
like any other app (`--new <path>` does the same without the panel). `japp save` shares the same workspace
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
| `JAppAppBundles` | YES | Run each app through its own app bundle (its own name in the menu bar, Dock, ⌘-Tab, notifications). |
| `JAppSingleProcess` | NO | Host every app in one process. |
| `JAppSetFinderIcons` | YES | Apply app icons to `.japp` files in Finder. |
| `JAppEditor` | first installed | Bundle id of the editor for Edit Source (`finder` for Finder). |
| `JAppEditWindowInFront` | YES | Keep the Edit Source window above other windows. |
| `JAppDeveloperMode` | NO | Developer mode for every app: Develop menu (Reload, zoom) and Inspect Element without ⌥. |
| `JAppAutomationDir`, `JAppAutomationScript`, `JAppAutomationQuit` | — | Test hooks used by `japp snapshot` and `Scripts/e2e-test.sh`. |
| `JAppAutomationContextMenus`, `JAppAutomationProbePoints`, `JAppAutomationMenuChoice` | — | Test hooks: right-click and hit-test page points; pick an item in `japp.menu.popup` menus. |
| `JAppAutomationAppBundles` | NO | Test hook: automation normally runs apps in-process; this goes through app bundles. |

Lifecycle events are logged to the unified log:
`log stream --predicate 'subsystem == "dev.japp.runtime"'`.
