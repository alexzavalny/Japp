# Testing

## Automated

```sh
swift test                 # 81 unit tests (JAppKit), no GUI needed
Scripts/build.sh && Scripts/install.sh
Scripts/e2e-test.sh        # integration checks, including the runtime regressions below (windows flash briefly)
swift build && python3 Scripts/runtime-regression-test.py  # network policy and unsaved documents
```

`runtime-regression-test.py` runs against the current debug executable without
installing it. Override `JAPP_RUNTIME` with an assembled app's
`Contents/MacOS/JAppRuntime` to test that build. It uses temporary archives and
app data, a loopback-only HTTP server and native automation actions. It checks
HTML, SVG iframe and worker requests with and without `network` (including CSP
on range responses); close/quit/reload cancellation and asynchronous saves;
edited-state fallback warnings; failed and removed handlers; and Paint's real
Save / Don’t Save / Cancel sheets and cancelled file saves. Successful asynchronous
saves are checked with a fixture that persists its contents before allowing exit;
actually choosing a destination in the system Save panel remains a manual check.
Automation actions are observed only when `JAppAutomationDir` is set; they use
`dev.japp.runtime.automation.app` with close/quit/reload and sheet-button actions.

**Unit tests** (`Tests/JAppKitTests`) cover the ZIP reader/writer (round trips;
interoperability with `zip`, `ditto` and Python's `zipfile` both ways; ZIP Slip,
symlinks, duplicates, encryption, unsupported methods, size-lying bombs,
corruption, truncation, limits), manifest parsing and validation, package
loading (wrapped folders, case-insensitive lookup, folder mode with symlink
escapes), packing (exclusions, atomic replace, failure keeps the original),
storage (JSON round trips, persistence, two writers merging) and source
workspaces (unpack, change tracking, save/backup/prune, invalid source refused,
external-change detection, broken manifests still editable, GUI + CLI sharing a workspace)
and app bundles (namespaced bundle ids, file-name sanitising, Info.plist without
handler keys, valid ad-hoc signature, reuse when current, rename in place keeping
the folder, `.icns` with every size, launch record following a moved file),
standalone apps (`japp export`: launcher, library and the unchanged archive inside,
the app id as bundle id, no runtime path or handler keys, hardened runtime with
the library-validation entitlement, valid signature, quarantine and icon attributes
not copied in, folders packed first, an existing app replaced only when asked,
invalid apps writing nothing, never into the app's own folder however its path is spelled)
and the new-app template (valid archive named after its file, replacing a file,
names escaped in HTML and JSON, ids from any script made unique, folders,
an AGENTS.md whose description of the workspace layout matches `SourceWorkspace`)
and `japp help` (every command the CLI dispatches is documented with its aliases,
every option a command parses is in its synopsis, topics are shipped docs, the
`--eval` recipe matches the starter app, lines fit in 100 columns).

**End-to-end tests** (`Scripts/e2e-test.sh`, data isolated in a temp directory)
check, on the real installed app:

* `japp pack` / `validate`; the output passes `unzip -t`;
* Launch Services maps `.japp` → `dev.japp.app` → JApp Runtime;
* `open Calculator.japp` (what a Finder double-click does) shows a window titled
  "Calculator" at 400×550 and gives the file its Finder icon;
* Paint (Tests/E2E/paint.test.js, synthetic pointer events, pixels read back):
  pencil, right-button colour, rectangle, flood fill, undo/redo, ellipse fill,
  Shift-snapped line, moving a selection, copy/paste, invert/flip/rotate/resize,
  aliased text, BMP and PNG encoding, 6× zoom, the Image toolbar menu as a native
  NSMenu with SF Symbols whose chosen item (Invert Colors) runs, toolbar state, titles,
  `japp.window.zoom`;
* app bundles: the app runs as `dev.japp.app.com.example.calculator` from
  `AppBundles/…/Calculator.app`, process and bundle named "Calculator", app menu
  names only the app, no runtime commands; JApp Runtime quits after the hand-over;
  the bundle is signed, declares no handlers and has the icon; launching the
  bundle on its own reopens its file; renaming the app renames the bundle in
  place; `japp bundles` lists and removes it; the app's File menu has Export as App…;
* standalone apps: `japp export` writes a signed `Calculator.app` with the runtime
  library and the unchanged `.japp` inside, the app id as bundle id and no handler
  keys, and keeps an existing app without `--force`; `japp export .` in an app folder
  writes the app next to the folder, not into it; a copy opened with `open`
  (what a double-click does) runs Calculator as "Calculator" (`com.example.calculator`)
  with the runtime loaded from inside itself and no JApp Runtime.app involved, has
  no Edit Source/Reveal/Export items, leaves its signature intact, and opens without
  a JApp prompt when the archive inside is quarantined;
* Calculator arithmetic through simulated keys and clicks: precedence, decimals,
  division by zero and recovery, backspace, grouping, operator replacement;
* `japp.storage` round trip, defaults, persistence across launches;
* permission denial, CSP blocking of remote fetches, same-origin fetch, 404s,
  `japp.window.setTitle`, frozen `window.japp`, no console errors;
* Edit Source from the terminal (`japp edit --no-window` → edit → `japp save`) and
  from the runtime window (its Save & Run code path, triggered via the automation
  hook): the change lands in the `.japp` and the relaunched app shows it; invalid
  source is refused and leaves the file intact; closing removes the workspace;
* New App (`--new`, the code path of *File › New App…* after its Save panel):
  the `.japp` is written, valid, named after the file, has its Finder icon and
  opens in Edit Source; following AGENTS.md (`japp save` the `archivePath` of
  `../session.json`) saves it; Save & Run runs it at 480×360; the Hello, World! page
  greets a typed name and remembers it across launches; JApp Runtime's File menu
  starts with New App… (app bundles have none); an unwritable location is reported;
* the Finder Services item "Edit JApp Source" (invoked with `NSPerformService`);
* `japp.http.fetch` against a local server that sends no CORS headers (works,
  while `fetch()` is blocked), refuses `file:` URLs, requires `network`;
* native feel (`Tests/E2E/NativeFeel`): default styles (no selection on labels,
  arrow cursor, no image drag, no page bounce, `data-selectable`), window state
  and title-bar metrics in CSS, hidden title bar and sidebar material, a menu
  bar without Reload/Zoom; drag regions hit-tested at real points (blank toolbar
  drags, its button does not, content does not); **real right-clicks** sent to the
  window: nothing on a label, an edit menu without browser items in a text
  field, only Inspect Element on ⌥-right-click, no link items; `japp.menu.popup`
  shows a native menu (with SF Symbols) and returns the chosen id; developer
  mode (folder) adds the Develop menu and Inspect Element;
* ZIP Slip archive rejected with nothing extracted; broken manifest reported;
  quarantined (downloaded) app requires confirmation.

`japp snapshot` is the building block: it runs an app headlessly, optionally
runs a script in the page, and writes a screenshot plus a JSON report.

## Also verified manually during development (2026-10-17/18, macOS 26.5, Apple Silicon)

* App bundles, without automation: `open build/Calculator.japp` and
  `open build/ChessResults.japp` ran as "Calculator" / "Chess Results"
  (`lsappinfo`: own display name, bundle id `dev.japp.app.…`, type Foreground);
  sampled every 30 ms during the hand-over, JApp Runtime only ever appeared as a
  `UIElement` (no Dock tile); opening the running file again activated it (one process).
  The bundle icon as drawn by `NSWorkspace.icon(forFile:)` is the app's icon, with
  no system frame added.

* Process per app: opening Calculator then Hello via Launch Services produced two
  runtime processes; re-opening either activated the existing process (log shows
  the request routed through the instance registry); `japp save --run` reloaded
  the app in its other process.
* In-place reload: Save & Run on a running app reloads it in the same process.
* Calculator layout at 300×400, 400×550 and 800×600; history panel; long results shrink to fit.
* Web platform inside apps: ES modules, workers (file and blob), `@font-face`,
  SVG images, audio metadata via range requests, `crypto.subtle`, IndexedDB,
  `localStorage`, `isSecureContext === true`.
* With `network`: a CORS-enabled HTTPS API returned 200; without it, the same request is blocked.
* `japp run --console` streams `console.*`, uncaught errors and failed resource loads.
* Chess Results example against the live Easy Chess Results API: tournament search
  (77 results, grouped), standings, player results, player search → profile →
  results, follow, Following dashboard, "new result" detection (badge + count),
  bookmarks, settings connection test. Notifications were not enabled (system prompt).
* The Edit Source and welcome windows (rendered to PNG through the automation hooks).
* Finder shows the Calculator icon on an opened file and the generic `.japp`
  icon on a copy without metadata (rendered with `NSWorkspace.icon(forFile:)`).
* Native feel in Chess Results: every screen rendered with the window frame
  (traffic lights over the sidebar, toolbar aligned with them); right-click on a
  standings row → *Follow* followed the player, *Show Results* opened their page
  and set the window title. Calculator with a hidden title bar: the top band
  drags, the history button does not.

## Needs a person at the Mac

These involve clicking system UI, permission prompts or looking at the screen,
which the automated environment could not do:

| Check | How |
|---|---|
| Double-click in Finder | Double-click `build/Calculator.japp`. Same Launch Services path as `open`, which is tested. |
| Right-click › Services / Quick Actions › **Edit JApp Source** appears in Finder's menu | The service is registered (`/System/Library/CoreServices/pbs -dump`) and works when invoked; if it is not listed, enable it in System Settings › Keyboard › Keyboard Shortcuts › Services › Files and Folders. |
| Clicking **Save** / **Save & Run** / **Discard** / closing with unsaved changes | Tested through the same methods, but not by clicking. |
| *File › New App…* (⌘N) and the welcome window's **New App…** button: the Save panel ("App Name:", Create, Replace) | Everything after the panel is tested (`--new`); the panel itself needs clicks. The welcome window with the new button was rendered to PNG. |
| Edit Source opening the workspace in **VS Code / Zed / Finder** | Uses `NSWorkspace.open(_:withApplicationAt:)`. Automated runs skip this step (so tests don't open windows in your editor); installed editors are detected by bundle id. |
| Dock tile shows the app's icon and name; ⌘-Tab; the bold menu-bar name | The process's name and bundle are verified (`lsappinfo`, report); the Dock and menu bar themselves were not looked at. |
| The app comes to the front after a Finder double-click | JApp Runtime yields activation to the app bundle. Tests start from a background terminal, where macOS does not let any app take focus, so this needs a real double-click. |
| Keep in Dock, then quit and click the Dock item | Covered by "launching the bundle itself" (`open <bundle>`), not by clicking the Dock. |
| `japp.dialog.openFile` / `saveFile` / `message`, `alert`/`confirm`/`prompt`, `<input type=file>`, downloads | Need clicks in panels. Permission enforcement for dialogs is tested. |
| `japp.notification.show` | Triggers the macOS permission prompt, now per app (System Settings › Notifications lists the app by name). |
| `japp.clipboard` with permission | Not run, to avoid overwriting the clipboard. |
| Paint with a real mouse and keyboard | Tools are tested with synthetic pointer events; real right-drags, the tool cursors, ⌘Z/⌘C/⌘V/⌘S and single-key tool shortcuts through WebKit, Open/Save panels, the system colour picker and dropping a file need a person. Dark mode was not rendered. |
| Quarantine prompt buttons (Open / Show Source…) | Detection is tested; the alert needs a click. |
| An exported app on a Mac without JApp Runtime, downloaded (Gatekeeper's *Open Anyway*) | The export is tested on this Mac: the app loads only the runtime inside it. Another Mac and Gatekeeper's dialogs need a person. |
| *File › Export as App…*: the Save panel | The item is in the app's File menu; the export after the panel is the same code as `japp export`. |
| *Open Calculator Example*, *Install Command-Line Tool…* menu items | Simple file operations; not clicked. |
| Dragging the window by a drag region; double-click to zoom | Hit-testing is tested; `performDrag(with:)` needs a physical mouse. |
| How the sidebar material and menus look on screen | Screenshots are rendered by the views themselves (the material shows as flat grey there); context menus were opened and read, not looked at. |

## Manual acceptance walkthrough (≈ 3 minutes)

1. `Scripts/build.sh && Scripts/install.sh`
2. In Finder, double-click `build/Calculator.japp` → Calculator opens in its own
   window titled "Calculator", with its own Dock icon; the file shows the calculator icon.
3. Calculate `12 + 7 × 3 =` (33) with the mouse and with the keyboard; try `8 ÷ 0`.
4. Click the clock icon → history; quit (⌘Q), reopen → history is still there.
5. Right-click `Calculator.japp` › Services › **Edit JApp Source** (or *File › Edit Source…*
   in the app). The source opens in your editor and the Edit Source window appears.
6. In `style.css`, change `--key-operator: #ff9f0a;` to `--key-operator: #30d158;`.
7. Click **Save & Run** → the calculator's operator keys turn green.
8. Quit and double-click `Calculator.japp` again → still green.
