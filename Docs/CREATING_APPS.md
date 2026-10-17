# Creating a JApp

A JApp is a folder of web files plus a `manifest.json`, zipped into one
`.japp` file. No compiler, bundler, Node.js or Xcode is needed — only an
editor and, optionally, the `japp` command that ships with JApp Runtime.

## The five-minute version

```sh
japp new "Todo List"                     # creates ./Todo List/ with a working app
japp run "Todo List" --console           # run it straight from the folder; JS console prints here
# …edit the files, press ⌘R in the app window to reload…
japp pack "Todo List" --output "Todo List.japp"
open "Todo List.japp"                    # or double-click it in Finder
```

## By hand

1. Make a folder with these files:

   **manifest.json**
   ```json
   {
     "manifestVersion": 1,
     "id": "com.yourname.todo",
     "name": "Todo List",
     "version": "1.0.0",
     "description": "A small todo list",
     "entry": "index.html",
     "icon": "assets/icon.png",
     "window": { "width": 420, "height": 560, "minWidth": 320, "minHeight": 400 },
     "permissions": ["storage"]
   }
   ```

   **index.html**
   ```html
   <!doctype html>
   <html lang="en">
   <head>
     <meta charset="utf-8">
     <title>Todo List</title>
     <link rel="stylesheet" href="style.css">
   </head>
   <body>
     <form id="add"><input id="text" placeholder="New todo" autofocus><button>Add</button></form>
     <ul id="list"></ul>
     <script type="module" src="app.js"></script>
   </body>
   </html>
   ```

   **app.js**
   ```js
   const list = document.getElementById("list");
   let todos = [];

   function render() {
     list.replaceChildren(...todos.map((todo, index) => {
       const item = document.createElement("li");
       item.textContent = todo;
       item.onclick = async () => { todos.splice(index, 1); await japp.storage.set("todos", todos); render(); };
       return item;
     }));
   }

   document.getElementById("add").onsubmit = async (event) => {
     event.preventDefault();
     const input = document.getElementById("text");
     if (!input.value.trim()) return;
     todos.push(input.value.trim());
     input.value = "";
     await japp.storage.set("todos", todos);
     render();
   };

   todos = await japp.storage.get("todos", []);   // top-level await: app.js is a module
   render();
   ```

   **style.css** — anything you like. **assets/icon.png** — a 1024×1024 PNG.

2. Zip the folder's *contents* and give the result a `.japp` extension:
   `japp pack ./Todo --output Todo.japp`, or `cd Todo && zip -r -X ../Todo.japp . -x '.*'`.

3. Double-click `Todo.japp`.

## Editing an existing app

* **In Finder:** right-click the `.japp` › *Services* (or *Quick Actions*) › **Edit JApp Source**.
* **In a running app:** *File › Edit Source…* (⌥⌘E).
* **In Terminal:** `japp edit App.japp`.

JApp unpacks the source into a workspace folder, opens it in your code editor
(VS Code, Cursor, Zed, Sublime Text, Nova, BBEdit… or Finder) and shows a small
*Edit Source* window. Edit the files, then click **Save** (repacks the `.japp`)
or **Save & Run** (repacks and shows the new version immediately). Saving
validates the app first and replaces the file atomically; the previous version
is kept in the workspace's `backups/` folder. Unsaved edits survive quitting —
choosing Edit Source again resumes them.

Terminal-only workflow (handy for scripts and AI assistants):

```sh
japp edit App.japp --no-window     # prints the source folder; opens nothing
# …edit files in that folder…
japp save App.japp --run           # validate, repack, reload the running app (or launch it)
japp save App.japp --close         # …and remove the workspace when done
```

You can also skip workspaces entirely: `japp unpack App.japp ./App`, edit, `japp pack ./App --output App.japp`.

## Checking your work

| Command | What it does |
|---|---|
| `japp validate App.japp` | Lists every error and warning; exit status 1 if invalid. |
| `japp run ./App --console` | Runs from the folder (no packing) and prints `console.*` output, uncaught errors and failed resource loads. Reload with ⌘R. |
| `japp snapshot App.japp -o shot.png` | Runs the app headlessly, saves a screenshot and prints a JSON report (window title, size, console messages). Exit status 1 on JS errors. |
| `japp snapshot App.japp --eval 'return document.title'` | Also runs JavaScript in the page (as an async function body) and includes its result. |
| `japp info App.japp` | Manifest summary, file list, data location. |
| `japp storage App.japp [--clear]` | Shows or clears the app's stored data. |

## Guidelines

* **Everything inside the app.** Without the `network` permission nothing loads
  from the internet — no CDNs, no web fonts. Copy libraries into the app folder
  (e.g. `lib/chart.min.js`) and reference them relatively.
* **Calling a web API?** Declare `"network"` and use `japp.http.fetch(url, options)`:
  it works like `fetch()` but is not blocked by CORS, so the API needs no changes.
* **Plain JavaScript works best.** No build step exists, so write browser-ready
  code: ES modules (`<script type="module">`) and modern JS run natively.
* **Relative paths.** `style.css`, `assets/icon.png`, `./lib/util.js`.
* **Declare what you use.** Add only the permissions the app needs; calls to
  undeclared capabilities fail with a clear `PERMISSION_DENIED` error.
* **Store data with `japp.storage`**, not in the archive. Data follows the
  `id`; keep the id stable across versions, change it to fork an app.
* **Design for resizing.** Use flexbox/grid and relative units; the window can
  be resized unless `"resizable": false`.
* **macOS look.** `color-scheme: light dark`, the system font (the default), and
  for dark single-window apps `"titleBarStyle": "hidden"` with a matching
  `"backgroundColor"`. See *Making it feel native* below.
* **Icon:** square 1024×1024 PNG with the artwork inset ~10% (macOS icons are a
  rounded square of 824×824 on a 1024 canvas).
* Use `alert`/`confirm`, `<input type="file">` and `<a download>` freely — they map to native panels.

## Making it feel native

The runtime already turns off what gives a web page away — text selection on
labels, the I-beam cursor, dragging images, the bouncing page, browser context
menus, Reload in the menu bar (details in [API.md](API.md#native-look-and-feel)).
The rest is up to the app's design:

* **No hover effects on content.** AppKit buttons, lists and tables do not light
  up under the pointer; they react when *pressed*. Use `:active`, not `:hover`
  (toolbar icon buttons are the exception). No `cursor: pointer` on buttons.
* **Native context menus.** Right-click on a list item should offer its actions:
  `japp.menu.popup([...])`, and outline the item while the menu is open.
* **Window chrome.** For a sidebar app use `"titleBarStyle": "hiddenInset"` and
  `"material": "sidebar"`: leave the sidebar transparent, put a toolbar
  `var(--japp-titlebar-height)` tall at the top of the content with
  `data-japp-drag-region`, and start the sidebar items below the traffic lights.
* **System colours and metrics.** `-apple-system-label`, `-apple-system-secondary-label`,
  `-apple-system-separator`; 13 px text, 24 px controls, 6–8 px corner radii,
  plain-case table headers and section titles (no uppercase), alternating table rows.
* **Inactive windows.** Fade accents and selections under
  `html[data-japp-window="inactive"]`.
* **Selectable where it helps.** Add `data-selectable` to values people copy
  (names, IDs, error messages).
* **Keyboard.** Handle the shortcuts a Mac user expects (⌘F to search, ⌘[ and ⌘]
  to go back and forward, Return to open, ⌘, for settings).
* **Progress.** A small spinner like NSProgressIndicator, not a skeleton screen.

Examples: [Calculator](../Examples/Calculator) (hidden title bar) and
[Chess Results](../Examples/ChessResults) (translucent sidebar, unified toolbar,
native context menus).

## For AI coding assistants

The format is designed to be produced in one pass. A checklist:

1. Create a folder named after the app containing `manifest.json`, `index.html`,
   `style.css`, `app.js` and (optionally) `assets/icon.png`.
2. `manifest.json` must have `"manifestVersion": 1`, a reverse-DNS `"id"`
   (`com.example.my-app` — letters, digits, hyphens, at least one dot), `"name"`,
   `"version"` (`"1.0.0"`), and `"permissions"` listing exactly what the code calls
   (`storage`, `dialog`, `notifications`, `clipboard`, `network`).
3. Use only relative URLs and files that exist in the folder. No CDN links unless
   `"network"` is declared. Call web APIs with `japp.http.fetch` (avoids CORS).
4. Persist state with `await japp.storage.get(key, default)` / `await japp.storage.set(key, value)`.
   Guard with `if (window.japp)` if the page should also work in a browser.
   Follow *Making it feel native* above: no `:hover` styles on content, native
   context menus via `japp.menu.popup`, and a drag region if the title bar is hidden.
5. Verify, then package:
   ```sh
   japp validate ./MyApp
   japp snapshot ./MyApp -o /tmp/check.png        # inspect the screenshot and the JSON report
   japp pack ./MyApp --output MyApp.japp
   ```
6. To change an existing `.japp`: `japp edit App.japp --no-window`, edit the
   printed folder, `japp save App.japp --run`.

If the `japp` command is unavailable, a valid app can still be produced with
`zip`: `cd MyApp && zip -r -X ../MyApp.japp . -x '.*'`.

See [FORMAT.md](FORMAT.md) for the full specification and [API.md](API.md) for `window.japp`.
