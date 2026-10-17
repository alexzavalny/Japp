# Security

JApp treats every `.japp` file as **untrusted input** and every app as
**untrusted code with declared, limited capabilities**, even though the MVP
targets apps you created or chose yourself. This document lists what is
enforced today and what is not.

## Threat model

| Asset | Threat | Main defence |
|---|---|---|
| Your files | An app reads or overwrites files it should not see | No file-system API; file access only through panels the user operates |
| Your file system | A crafted archive writes outside its folder when unpacked ("ZIP Slip") | Strict name validation before anything is extracted, plus a containment check per file |
| Memory/disk | A "zip bomb" | Size/entry limits, decompression capped at the declared size, overlap detection |
| Other apps' data | One app reads another app's storage, localStorage or cookies | Per-app origin, per-app WebKit data store, per-app storage directory, bridge checks origin |
| Your Mac | An app runs commands | No shell, process or arbitrary native API is exposed — only the bridge modules |
| Your privacy | An app exfiltrates data over the network | No network access unless the app declares `network` (CSP for web content, a permission check for `japp.http`) |
| Trust | A downloaded app runs without you noticing | One-time confirmation for quarantined files |

## What is enforced

**Archive (JAppKit `ZipArchive`)**
* Rejects absolute paths, `..`/`.`/empty components, backslashes, drive letters,
  control characters, names > 1024 bytes, symbolic links, encrypted entries,
  unsupported compression, ZIP64, multi-volume archives, duplicate names
  (case/normalisation-insensitive), and entries whose data overlaps.
* Limits: 256 MB archive, 10,000 entries, 256 MB per file, 1 GB total.
* Decompression never produces more than the declared size; CRC-32 is checked on every read.
* Running an app extracts nothing. Unpacking for editing re-validates and checks
  every destination resolves inside the workspace.

**Manifest**: validated in full before anything is shown; invalid apps do not run.

**Web view**
* Each app runs at its own origin `japp-resource://<id>/`; the scheme handler only
  serves that app's files and only `GET`/`HEAD`.
* A `Content-Security-Policy` header is sent with every page. Without `network`:
  `default-src 'self' japp-resource: data: blob:` (and the same for scripts, styles,
  images, fonts, media, connections, frames, workers), `object-src 'none'`,
  `base-uri 'self'`, `form-action 'self'`. Inline scripts and `eval` stay allowed
  because plain-JS apps commonly need them; the policy's job is to keep data in.
* Navigation policy: the main frame may only navigate within the app's origin;
  web links open in the default browser; `window.open` never creates windows;
  other schemes are blocked. Sub-frames may load the web only with `network`.
* Camera/microphone requests are denied. `javaScriptCanOpenWindowsAutomatically` is off.
* WebKit's own protections are unchanged (no `allowFileAccessFromFileURLs`, no
  disabled web security). Two WebKit SPI preferences are used, both for
  presentation only: `drawsBackground` (a transparent page over a window
  material, only when the manifest asks for one) and `developerExtrasEnabled`
  (Inspect Element in the context menu, shown on ⌥-right-click).
* Context menus never offer to open, download or copy links and images; there is
  no way to navigate the app window from a menu.
* Each app id has its own `WKWebsiteDataStore`; web content runs in WebKit's
  sandboxed content process.

**Bridge (`NativeBridge`)**
* Accepts messages only from the app's own **main frame** and **origin**. Remote
  content (in iframes, with `network`) cannot call native code; same-origin
  iframes are the app's own files and are treated as the app.
* Every method is mapped to a permission, checked natively; there is no generic
  "call native" path. Methods without a permission (`japp.window`, `japp.menu`,
  `japp.dialog.message`) only affect the app's own window and menus. Messages are size-limited (48 MB) and arguments type-checked.
* File access only through `NSOpenPanel`/`NSSavePanel` driven by the user; apps
  receive names and contents, never paths. Opened files are limited to 32 MB.

**Storage**: per-id directory, size limits, atomic writes under a lock.

**Downloaded apps**: if the `.japp` has the `com.apple.quarantine` attribute
(set by browsers, Mail, AirDrop…), the runtime shows the app's name, id and
requested permissions and asks before the first run, offering to show the
source instead. Confirming removes the attribute, as Gatekeeper does.

**Saving edits**: validated before writing; atomic replacement; previous
version kept in `backups/`; concurrent external modification detected.

## Known limitations

* **No process sandbox for the runtime.** JApp Runtime is not built with the App
  Sandbox, so the guarantees above rest on the runtime's own code and WebKit's
  content-process sandbox, not on the kernel. A bug in the runtime's native side
  (e.g. in a bridge module) would run with the user's privileges. Adopting the App
  Sandbox (with security-scoped bookmarks for opened files) is the main hardening step.
* **Ad-hoc code signature.** The locally built runtime is not signed with a
  Developer ID or notarized; distribution to other Macs requires that.
* **Permissions are declared, not granted.** Declaring a permission in the
  manifest is enough to use it (except for downloaded apps, which ask once, and
  notifications, which macOS asks about). There is no per-permission prompt and no
  way to revoke one permission for one app.
* **`network` is all-or-nothing.** No per-host allow-list yet. With it, an app can
  also use `japp.http.fetch`, which is not subject to CORS: it can read responses
  from any reachable server, including ones on your local network. It never sends
  cookies, cached data or stored credentials, so it cannot act within your web sessions.
* **Shared identity.** Notifications and the menu-bar name show "JApp Runtime".
  An app can set its window title to anything, including another app's name.
* **Same id, same data.** Any app can claim any id and thereby read that id's
  storage. Ids are not tied to a signature or author. (Fine for personal use;
  signing apps would be needed before sharing them widely.)
* **Inline script and eval are allowed** inside the app's own origin.
* **Edit workspaces are ordinary files** under `~/Library/Application Support/JApp/Workspaces`
  and readable by other processes running as you.
* **Finder icon metadata** is written to `.japp` files the runtime opens
  (opt out with `JAppSetFinderIcons = NO`).
* The automation defaults (`JAppAutomation*`) let a local process script an app
  and read its page; they are a developer tool and affect only processes started with them.
