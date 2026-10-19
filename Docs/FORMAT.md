# The JApp file format (version 1)

A JApp is **one file with the extension `.japp`**. It is a standard ZIP archive
that contains a web app (HTML, CSS, JavaScript and assets) plus a
`manifest.json` describing it. Rename it to `.zip` and any archive tool opens it.

```
Calculator.japp            (a ZIP archive)
├── manifest.json          required, at the root
├── index.html             the entry page (name set by "entry")
├── style.css
├── app.js
└── assets/
    └── icon.png           the app icon (path set by "icon")
```

Everything an app needs is inside the archive. The only thing outside it is the
shared JApp Runtime, which is installed once. No build step, compiler or
package manager is involved: write the files, zip them, double-click.

For a Mac without JApp Runtime, `japp export App.japp` wraps the archive, unchanged,
in a standalone `App.app` that carries the runtime too
([CREATING_APPS.md › Sharing an app](CREATING_APPS.md#sharing-an-app)). The format
is the same either way: the `.app` contains the `.japp` file.

## 1. Archive rules

| Rule | Detail |
|---|---|
| Container | ZIP, single volume, no encryption, no ZIP64 (so archives are < 4 GB). |
| Compression | *Store* (0) or *Deflate* (8). Every common tool produces these. |
| File names | UTF-8, relative, `/`-separated. |
| Root | `manifest.json` at the root of the archive, **or** inside a single top-level folder (what Finder's *Compress* produces). |
| Ignored | `__MACOSX/…`, `.DS_Store` and `._*` entries are skipped. |
| Rejected | Absolute paths, `..` or `.` components, empty components, backslashes, drive letters, control characters, symbolic links, duplicate names (compared case- and Unicode-normalisation-insensitively), entries that overlap or lie about their size. |
| Limits | Archive ≤ 256 MB; ≤ 10,000 entries; each file ≤ 256 MB uncompressed; total ≤ 1 GB uncompressed; names ≤ 1024 bytes. |

The runtime refuses an archive that breaks any rule instead of trying to repair it.

### Creating an archive

With the CLI (validates first, writes atomically):

```sh
japp pack ./Calculator --output Calculator.japp
```

With standard tools — zip the *contents* of the folder, not the folder:

```sh
cd Calculator && zip -r -X ../Calculator.japp . -x '.*'
```

Finder's *Compress* also works (it wraps the files in a folder, which is allowed);
rename the resulting `.zip` to `.japp`.

`japp pack` leaves out hidden files (`.git`, `.DS_Store`, `.vscode`, …), `__MACOSX`,
`Thumbs.db` and editor backups ending in `~`, and refuses symbolic links.

## 2. manifest.json

```json
{
  "manifestVersion": 1,
  "id": "com.example.calculator",
  "name": "Calculator",
  "version": "1.0.0",
  "description": "A simple calculator",
  "author": "Example Inc.",
  "entry": "index.html",
  "icon": "assets/icon.png",
  "window": {
    "width": 400,
    "height": 550,
    "minWidth": 300,
    "minHeight": 400,
    "resizable": true,
    "titleBarStyle": "transparent",
    "backgroundColor": "#1C1C1E"
  },
  "permissions": ["storage"]
}
```

| Field | Required | Type | Meaning |
|---|---|---|---|
| `manifestVersion` | yes | integer | Format version. Must be `1` for this runtime. |
| `id` | yes | string | Unique app identifier in reverse-DNS form: at least two dot-separated segments of letters, digits and hyphens (no leading/trailing hyphen), ≤ 128 characters. Case-insensitive. **Identifies the app's data** (see §4). |
| `name` | yes | string | Display name: window title, menus, About box. ≤ 100 characters, no line breaks. |
| `version` | yes | string | `MAJOR[.MINOR[.PATCH[.BUILD]]]` with an optional `-pre` or `+build` suffix, e.g. `1.0.0`, `2.1.0-beta.1`. |
| `description` | no | string | One-line description (About box, `japp info`). |
| `author` | no | string | Shown in the About box. |
| `entry` | no | string | The HTML page to open. Default `index.html`. Must be `.html`, `.htm` or `.xhtml`. |
| `icon` | no | string | Path to the icon inside the archive. PNG recommended, square, 1024×1024 (JPEG, ICNS, TIFF, GIF, HEIC also accepted; SVG best-effort). |
| `window` | no | object | Initial window (below). |
| `permissions` | no | array of strings | Native capabilities the app uses (§3). |

`window` fields:

| Field | Default | Meaning |
|---|---|---|
| `width`, `height` | 800, 600 | Initial content size in points (100–16384). |
| `minWidth`, `minHeight` | none | Minimum content size; must not exceed the initial size. |
| `maxWidth`, `maxHeight` | none | Maximum content size; must not be below the initial size. |
| `resizable` | `true` | Whether the user can resize the window. |
| `titleBarStyle` | `"default"` | `"default"`; `"transparent"` (the title bar takes `backgroundColor` and blends with the page); `"hidden"` (no title bar: the page fills the window and the traffic lights float over it, as in Calculator); `"hiddenInset"` (the same with the taller band of apps that have a toolbar, as in Finder or Mail). With the hidden styles the page tells the runtime where the window can be dragged — see *Native look and feel* in [API.md](API.md). |
| `material` | none | A system material behind the page, visible wherever the page is transparent: `"sidebar"`, `"window"`, `"underWindow"`, `"contentBackground"`, `"headerView"`, `"titlebar"`, `"menu"`, `"popover"`, `"hud"`, `"sheet"`. |
| `backgroundColor` | none | `#RGB`, `#RRGGBB` or `#RRGGBBAA`. Shown before the page paints and behind a transparent title bar. |

Paths (`entry`, `icon`) are relative to the app root and may not leave it.

### Compatibility rules

The format is designed to grow without breaking existing apps:

* **Unknown keys are ignored.** New optional fields can be added in later runtimes.
* **Unknown permissions and unknown enum values are warnings**, not errors: an app
  written for a newer runtime still opens; the unknown capability is simply absent.
* A **`manifestVersion` greater than the runtime supports is an error** ("requires a
  newer JApp Runtime"). It is only incremented for changes old runtimes cannot ignore safely.

### Validation

The runtime validates the archive and manifest before showing anything, and
reports every problem at once in plain language, for example:

```
✗ Broken.japp is not valid:
  error: id: “nodots” is not a valid identifier; use reverse-DNS form such as “com.example.calculator”
  error: window.width: must be between 100 and 16384 (got 50)
```

Run the same checks yourself with `japp validate App.japp` (or on a folder).
Warnings (missing or small icon, remote resources without the `network`
permission, unknown permissions) never stop an app from running.

## 3. Permissions

An app gets a native capability only if it declares it. Undeclared calls reject
with a `JAppError` whose `code` is `"PERMISSION_DENIED"` and whose message names the fix.

| Permission | Grants |
|---|---|
| `storage` | `japp.storage.*` — persistent key-value storage. |
| `dialog` | `japp.dialog.openFile` and `japp.dialog.saveFile` — files the user picks in a standard panel. |
| `notifications` | `japp.notification.show`. |
| `clipboard` | `japp.clipboard.readText` / `writeText`. |
| `network` | Loading anything from `http:`, `https:`, `ws:` or `wss:` (fetch, images, scripts, iframes), and `japp.http.fetch` (native requests without CORS). Without it, the app is limited to its own files. |

Always available without a permission: `japp.app`, `japp.window.*`,
`japp.dialog.message`, standard web features (`alert`, `confirm`, `prompt`,
`<input type="file">`, `<a download>`, `localStorage`, IndexedDB), and links to
web pages, which open in the default browser.

## 4. Identity and data

* App data never goes into the archive. The archive is code and static resources only.
* `japp.storage` data lives in `~/Library/Application Support/JApp/Apps/<id>/storage.json`
  (human-readable JSON). `localStorage`, IndexedDB and cookies live in a WebKit data
  store reserved for the same id.
* Data belongs to the **id**, not the file name: renaming or moving the `.japp`
  keeps its data; editing and saving it keeps its data.
* An app exported with `japp export` uses the same `japp.storage` file as its
  `.japp` on the same Mac, but its own WebKit data store: `localStorage`, IndexedDB
  and cookies are not shared between the two.
* **Two files with the same id share the same data** (like two copies of the same
  Mac app). Running both at once is safe — every write merges at the key level
  under a file lock — but they see each other's values. To make an independent
  copy, give it a different `id`.

## 5. How the app is served

Files are served from the archive in memory, never extracted, at
`japp-resource://<id>/<path>`. The entry page of Calculator is therefore
`japp-resource://com.example.calculator/index.html`. Consequences for authors:

* Use **relative URLs** (`style.css`, `assets/logo.svg`) or root-relative ones
  (`/assets/logo.svg`); both work. ES modules, `fetch()` of bundled files,
  web workers, fonts, images, audio and video all work.
* The page is a **secure context** (`window.isSecureContext === true`), so
  `crypto.subtle` and similar APIs are available.
* A missing file returns HTTP 404; lookups fall back to a case-insensitive match.
* `file:` URLs and other apps' origins are not reachable.
* Requests to web APIs (with the `network` permission) via `fetch()` follow
  normal browser CORS rules; APIs that send `Access-Control-Allow-Origin: *` work.
  For any other API use `japp.http.fetch`, which is not subject to CORS.

## 6. MIME type and file extension

* Extension: `.japp`
* Uniform Type Identifier: `dev.japp.app` (conforms to `public.data`, `public.content`)
* MIME type: `application/vnd.japp+zip`
