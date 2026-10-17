# Chess Results (JApp)

A desktop client for [Easy Chess Results API](https://github.com/alexzavalny/ChessResultsApi):
search Chess-Results tournaments, read standings and game-by-game results,
browse the player index, and follow players — their latest results refresh
automatically, with an optional notification when a new round is played.

* **Tournaments** — federation + end-date search, Blitz/Rapid/Classical filter, bookmarks.
* **Standings** — round selector, tie-breaks, player filter; click a player for results.
* **Player results** — rank, points, performance, rating change, colour and result per round.
* **Players** — search the API's player index; profiles list every tournament played.
* **Following** — dashboard of followed players with recent results and "new result" badges.
* **Settings** — API address (default: the project's ngrok endpoint), optional API key,
  default federation, refresh interval, notifications.

Requests use `japp.http.fetch` (permission `network`), which is not subject to
browser CORS, so the API does not need to list this app's origin in
`CORS_ALLOWED_ORIGINS`. The `ngrok-skip-browser-warning` header is sent so
ngrok's free tier returns JSON rather than its warning page.

Data (settings, followed players, bookmarks) is stored with `japp.storage`.

It is built to feel like a Mac app: a translucent sidebar under the traffic
lights (`"titleBarStyle": "hiddenInset"`, `"material": "sidebar"`), a toolbar
that drags the window (`data-japp-drag-region`), system colours, controls that
react when pressed rather than on hover, a native spinner, and right-click menus
on tournaments, players and followed cards (`japp.menu.popup`). Player names and
details are selectable (`data-selectable`); everything else behaves like labels.

```sh
japp run Examples/ChessResults --console      # run from source
japp pack Examples/ChessResults --output "Chess Results.japp"
```
