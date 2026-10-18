# JavaScript API (`window.japp`)

JApp Runtime injects `window.japp` into every app before the app's own scripts
run. It is a frozen object; native operations return a **Promise**.

```js
await japp.storage.set("username", "Alex");
const username = await japp.storage.get("username");          // "Alex"
```

Calls that fail reject with a `japp.JAppError`, which has a `code` and a
human-readable `message`:

| `code` | Meaning |
|---|---|
| `PERMISSION_DENIED` | The manifest does not declare the permission the method needs. The message says what to add. |
| `BAD_ARGUMENTS` | A required argument is missing or has the wrong type. |
| `NOT_SUPPORTED` | The module or method does not exist in this runtime version. |
| `NOT_AUTHORIZED` | macOS refused (e.g. notifications are turned off for the app). |
| `NETWORK_ERROR` | `japp.http.fetch` could not connect (offline, DNS, TLS, timeout). |
| `STORAGE_ERROR` | Invalid key/value or a storage quota was hit. |
| `FAILED` | Anything else (the message explains). |
| `UNAVAILABLE` | `window.japp` is used outside JApp Runtime. |

```js
try {
  await japp.clipboard.readText();
} catch (error) {
  if (error.code === "PERMISSION_DENIED") console.warn(error.message);
}
```

## japp.app

Synchronous, frozen information about the running app (from `manifest.json`):

```js
japp.app.id            // "com.example.calculator"
japp.app.name          // "Calculator"
japp.app.version       // "1.0.0"
japp.app.description   // "" if none
japp.app.permissions   // ["storage"]
japp.hasPermission("network")   // false
japp.runtimeVersion    // "0.3.0"
```

## japp.storage — permission `storage`

Persistent key-value storage. Values are any JSON value (objects, arrays,
strings, numbers, booleans, `null`); they keep their types exactly. Data
survives restarts and edits of the app, and is shared by every copy of the app
with the same `id`. It is stored as readable JSON in
`~/Library/Application Support/JApp/Apps/<id>/storage.json`.

| Method | Result |
|---|---|
| `get(key, defaultValue = null)` | The stored value, or `defaultValue` if the key is absent. |
| `set(key, value)` | Stores `value`. Throws `TypeError` if it is not JSON-serialisable (`undefined`, functions). |
| `remove(key)` | Deletes the key. |
| `clear()` | Deletes every key of this app. |
| `keys()` | Array of all keys, sorted. |

Limits: keys 1–512 characters, values ≤ 5 MB of JSON, ≤ 50 MB per app.

```js
const todos = await japp.storage.get("todos", []);
todos.push({ text: "Write docs", done: false });
await japp.storage.set("todos", todos);
```

`localStorage` and IndexedDB also work and are isolated per app; prefer
`japp.storage` for data the user cares about — it is a plain file you can
inspect, back up and reset (`japp storage <app>`).

## japp.dialog

### `openFile(options)` — permission `dialog`

Shows an Open panel. Resolves to `null` if the user cancels.

| Option | Default | Meaning |
|---|---|---|
| `accept` | any file | Array of extensions (`"txt"`, `".json"`), MIME types (`"image/png"`) or `"image/*"`, `"audio/*"`, `"video/*"`, `"text/*"`. |
| `multiple` | `false` | Allow several files; the result is then an array. |
| `encoding` | `"text"` | `"text"` (UTF-8), `"base64"` or `"dataURL"`. |
| `title` | — | Message shown in the panel. |

Each file is `{ name, size, type, text | base64 | dataURL }`. The app receives the
file's name and contents, never its path. Files are limited to 32 MB.

```js
const file = await japp.dialog.openFile({ accept: ["json"] });
if (file) data = JSON.parse(file.text);
```

### `saveFile(options)` — permission `dialog`

Shows a Save panel and writes the content to the chosen file. Resolves to
`{ name, size }`, or `null` if the user cancels.

| Option | Meaning |
|---|---|
| `content` | **Required.** A string. |
| `encoding` | `"text"` (default) or `"base64"` for binary data. |
| `suggestedName` | Initial file name. |
| `accept`, `title` | As for `openFile`. |

```js
await japp.dialog.saveFile({ suggestedName: "notes.md", content: markdown });
```

### `message(options)` — no permission

A native alert sheet. Resolves to the index of the clicked button.

```js
const choice = await japp.dialog.message({
  title: "Delete all items?",
  message: "This cannot be undone.",
  buttons: ["Delete", "Cancel"],   // up to 4; default ["OK"]
  style: "warning",                // "informational" (default), "warning", "critical"
});
if (choice === 0) deleteAll();
```

The standard `alert()`, `confirm()` and `prompt()` also work and show native sheets.

## japp.notification — permission `notifications`

```js
await japp.notification.show({ title: "Timer done", body: "Time for a break", sound: true });
```

`subtitle` is optional. The first call asks macOS for permission. Notifications
come from the app itself — its name and icon, its own entry in System Settings ›
Notifications — because every app runs from a bundle of its own (ARCHITECTURE.md,
*App identity*). Only when an app runs inside JApp Runtime (`japp run --console`,
`JAppAppBundles NO`) are they sent as JApp Runtime, with the app's name as the
default subtitle.

## japp.clipboard — permission `clipboard`

```js
await japp.clipboard.writeText("Copied!");
const text = await japp.clipboard.readText();   // null if the clipboard has no text
```

Without the permission, standard `copy` / `paste` events still work for
user-initiated ⌘C / ⌘V.

## japp.http — permission `network`

Native HTTP requests for talking to web APIs. Unlike `fetch()`, they are not
subject to CORS, so an API does not have to allow the app's `japp-resource://`
origin. Requests never carry cookies, cached data or saved credentials.

```js
const response = await japp.http.fetch("https://api.example.com/items?q=chess", {
  method: "GET",                       // GET, HEAD, POST, PUT, PATCH, DELETE, OPTIONS
  headers: { Authorization: "Bearer …" },
  body: { name: "value" },             // string, or any JSON value (sent as application/json)
  timeout: 30,                         // seconds, 1–120 (default 30)
  responseType: "text",                // or "base64" for binary data
});
response.ok;        // true for 2xx
response.status;    // 200
response.headers;   // { "content-type": "application/json", … } (lower-case names)
await response.json();
await response.text();
await response.arrayBuffer();
```

HTTP errors (404, 500…) resolve normally with `ok: false`; failures to connect
reject with code `NETWORK_ERROR`. Only `http:` and `https:` URLs are allowed;
responses are limited to 32 MB.

Plain `fetch()` also works with the `network` permission, with normal browser
CORS rules — use it for APIs that send `Access-Control-Allow-Origin: *`.

## japp.menu — no permission

Native context menus: a real macOS menu (with SF Symbols icons if you like)
instead of an HTML imitation. Resolves to the `id` of the chosen item, or `null`
if the menu was dismissed.

```js
row.addEventListener("contextmenu", async (event) => {
  event.preventDefault();
  const choice = await japp.menu.popup([
    { id: "open", label: "Open", symbol: "arrow.up.forward.square" },
    { id: "star", label: "Favorite", checked: isFavorite },
    "-",                                                    // separator
    { label: "Share", submenu: [{ id: "copy", label: "Copy Link" }] },
    { id: "delete", label: "Delete", enabled: canDelete },
  ], { x: event.clientX, y: event.clientY });              // position: default is the pointer
  if (choice === "open") open();
});
```

| Item field | Meaning |
|---|---|
| `label` | **Required.** The title. |
| `id` | Returned when chosen (default: the label). |
| `enabled`, `checked` | Default `true` and `false`. |
| `symbol` | An SF Symbols name, e.g. `"star"`, `"trash"`, `"safari"`. |
| `shortcut` | Shown on the right, e.g. `"cmd+z"`, `"cmd+shift+z"`, `"⌘⌥I"`, `"ctrl+pagedown"`, `"delete"`. Only for display (and while the menu is open): the page still handles the keys. |
| `submenu` | An array of items (up to 4 levels). |

`"-"` or `{ type: "separator" }` is a separator; a menu holds at most 300 items.

## japp.window — no permission

Controls the app's own window.

```js
await japp.window.setTitle("Untitled — My Editor");
await japp.window.minimize();
await japp.window.zoom();      // like double-clicking the title bar (zoom / restore)
await japp.window.close();     // requests closing; unsaved-work protection can cancel it
```

### Protecting unsaved work

Mark documents as edited whenever their contents change, and clear the flag only
after a successful save. This also updates the window's native edited indicator.

```js
await japp.window.setDocumentEdited(true);

const removeHandler = japp.window.onBeforeClose(async ({ reason }) => {
  // reason is "close", "quit" or "reload" (including Save & Run).
  if (!dirty) return true;
  const choice = await japp.dialog.message({
    message: "Save your changes?", buttons: ["Save", "Don’t Save", "Cancel"],
  });
  if (choice === 2) return false;
  if (choice === 0) {
    const saved = await saveDocument(); // false if the user cancels the Save panel
    if (!saved) return false;
    dirty = false;
    await japp.window.setDocumentEdited(false);
  }
  return true;
});
```

The close button, ⌘W, `japp.window.close()`, ⌘Q and reload all wait for the
handler. Return **`true`** to proceed; any other result cancels. Multiple handlers
must all approve. Registration is synchronous and returns an unsubscribe function
(`removeHandler()`); handlers must not call `close()` themselves.

Repeated requests share the pending decision. A failed handler opens a native
warning instead of silently losing work. An edited document with no handler gets
the same warning, offering **Keep Open** or **Discard Changes**. Apps must opt in
by marking their edited state or registering a handler; this does not provide
recovery after crashes or Force Quit. Paint uses this API for Save / Don’t Save / Cancel.

## Native look and feel

JApp Runtime makes a page behave like a Mac app rather than a web page. All of it
can be overridden from the app's own CSS.

**Defaults** — injected as the first stylesheet, with zero specificity (`:where`),
so any rule of yours wins:

| Default | Opt out / opt in |
|---|---|
| Text is not selectable, except in text fields and `contenteditable` | `data-selectable` on an element (and its contents), or `-webkit-user-select: text` |
| Arrow cursor (no I-beam over labels); text fields show the I-beam | `cursor: auto` |
| Images and links cannot be dragged out | `draggable="true"` |
| The page does not rubber-band (inner scroll areas still do) | `overscroll-behavior: auto` on `html` |
| System font (San Francisco) | any `font-family` |

**Context menus** appear only where macOS shows them: in text fields (Cut, Copy,
Paste, Spelling…) and on selected text (Look Up, Translate, Copy…), never with
browser items (Back, Reload, Open Link, Download Image…). Build your own with
[`japp.menu.popup`](#jappmenu--no-permission). ⌥-right-click adds Inspect Element.

**Menu bar** — no Reload or page zoom: those live in a *Develop* menu that appears
only in developer mode (apps run from a folder, `japp run --develop`, `--console`,
an app whose source is being edited, or `defaults write dev.japp.runtime JAppDeveloperMode -bool YES`).
⌘R, ⌘+ and ⌘− are free for the app otherwise.

**Window state for CSS**, set on `<html>`:

| | |
|---|---|
| `data-japp-window="active"` / `"inactive"` | Whether the window is the main window. Dim selections and accents when inactive, as AppKit does. |
| `data-japp-fullscreen` | Present in full screen. |
| `--japp-titlebar-height` | With `"titleBarStyle": "hidden"` or `"hiddenInset"`: the height of the band the traffic lights sit in (32 / 52 px; 0 in full screen). Make your toolbar this tall. |
| `--japp-titlebar-inset` | Width to keep clear on the left for the traffic lights. |

```css
.toolbar { height: max(52px, var(--japp-titlebar-height)); padding-left: var(--japp-titlebar-inset); }
html[data-japp-window="inactive"] .sidebar .selected { background: -apple-system-unemphasized-selected-content-background; }
```

**Moving the window.** With a hidden title bar the page covers the whole window,
so the page says where the window can be dragged: give elements
`data-japp-drag-region`. Buttons, links, fields and other controls inside stay
clickable (mark anything else with `data-japp-no-drag`); double-clicking a drag
region zooms or minimizes the window, following System Settings. A page without
any drag region gets one automatically: the title-bar band, minus its controls.

```html
<header class="toolbar" data-japp-drag-region>
  <h1>Inbox</h1> <button>Compose</button>
</header>
```

**System colours.** WebKit understands the macOS colour names, which follow light
and dark mode and the user's accent colour: `-apple-system-label`,
`-apple-system-secondary-label`, `-apple-system-tertiary-label`,
`-apple-system-separator`, `-apple-system-control-background`,
`-apple-system-control-accent`, `-apple-system-selected-content-background`,
`-apple-system-unemphasized-selected-content-background`, and the CSS `AccentColor`.

**Translucency.** `"material": "sidebar"` in the manifest's `window` puts the
system material behind the page; it shows wherever the page has no background
(e.g. give `html, body` no background and paint only the content area).

## Standard web platform

Apps are normal web pages running in Safari's engine (WebKit), so the web
platform is available: DOM, Canvas, WebGL, Web Audio, `fetch`, ES modules,
workers, `crypto.subtle`, `localStorage`, IndexedDB, CSS (including container
queries). Notable behaviours:

* `<input type="file">` opens a native Open panel; `<a download>` and blob
  downloads open a Save panel.
* Links to `http(s):` pages open in the default browser, never inside the app window.
* `window.open()` of a web page opens it in the browser; apps have one window.
* Camera and microphone requests are denied, and geolocation is not supported
  (neither is part of the permission model yet).
* Without the `network` permission, nothing loads from outside the app.
* **Inspect Element**: ⌥-right-click anywhere (no ⌥ needed in developer mode), or
  attach from Safari › Develop › *this Mac* › the app.

## Detecting the runtime

`window.japp` exists only inside JApp Runtime. To keep an app usable in a
normal browser during development, fall back to `localStorage`:

```js
const storage = window.japp ? japp.storage : {
  async get(key, fallback = null) { const v = localStorage.getItem(key); return v === null ? fallback : JSON.parse(v); },
  async set(key, value) { localStorage.setItem(key, JSON.stringify(value)); },
};
```

## Protocol (for runtime implementers)

`window.japp` is a thin wrapper. Each call posts a JSON string
`{"module": "...", "method": "...", "args": {...}}` to the WebKit message handler
`japp` and receives a JSON string `{"ok": true, "value": ...}` or
`{"ok": false, "error": {"code": "...", "message": "..."}}`. All authority lives
in the native side: messages are accepted only from the app's own main frame
and origin, and permissions are checked there.
