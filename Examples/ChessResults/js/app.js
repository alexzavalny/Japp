// Chess Results — a JApp client for the Easy Chess Results API.
// Hash-based navigation: #/following, #/tournaments, #/tournament/<id>,
// #/tournament/<id>/player/<start number>, #/players, #/player/<key>, #/settings.

import { refreshAll, scheduleRefresh } from "./following.js";
import { loadState, state, subscribe, toggleBookmark } from "./store.js";
import { chessResultsUrl } from "./api.js";
import { contextMenu, h, icon, openExternal } from "./ui.js";
import {
  followingView, playerProfileView, playerResultsView, playersView, settingsView, tournamentView, tournamentsView,
} from "./views.js";

const routes = [
  [/^#\/following$/, () => followingView],
  [/^#\/tournaments$/, () => tournamentsView],
  [/^#\/tournament\/(\d+)$/, (match) => (page) => tournamentView(page, match[1])],
  [/^#\/tournament\/(\d+)\/player\/([\w-]+)$/, (match) => (page) => playerResultsView(page, match[1], match[2])],
  [/^#\/players$/, () => playersView],
  [/^#\/player\/(.+)$/, (match) => (page) => playerProfileView(page, decodeURIComponent(match[1]))],
  [/^#\/settings$/, () => settingsView],
];

const elements = {
  sidebar: document.getElementById("sidebar"),
  title: document.getElementById("title"),
  subtitle: document.getElementById("subtitle"),
  actions: document.getElementById("actions"),
  content: document.getElementById("content"),
};

const memory = {}; // view state that survives navigation (search filters, results…)
let generation = 0;

function defaultRoute() {
  return state.following.length ? "#/following" : "#/tournaments";
}

async function route() {
  const hash = location.hash && location.hash !== "#" ? location.hash : defaultRoute();
  const current = ++generation;
  const match = routes.map(([pattern, view]) => [hash.match(pattern), view]).find(([found]) => found);
  const view = match ? match[1](match[0]) : tournamentsView;

  const page = {
    body: h("div", { class: "page" }),
    memory,
    isCurrent: () => current === generation,
    navigate: (target) => {
      if (location.hash === target) route();
      else location.hash = target;
    },
    reload: () => route(),
    title(title, subtitle = "") {
      if (current !== generation) return;
      elements.title.textContent = title;
      elements.subtitle.textContent = subtitle;
      // The window title is hidden, but the Window menu and Mission Control show it.
      window.japp?.window.setTitle(title || "Chess Results").catch(() => {});
    },
    actions(...nodes) {
      if (current === generation) elements.actions.replaceChildren(...nodes.flat().filter(Boolean));
    },
  };
  elements.actions.replaceChildren();
  elements.content.replaceChildren(page.body);
  elements.content.scrollTop = 0;
  renderSidebar(hash);
  try {
    await view(page);
  } catch (error) {
    console.error(error);
  }
}

// ---------------------------------------------------------------------------
// Sidebar

function navItem(hash, label, iconName, current, badge) {
  const active = current === hash || (hash === "#/tournaments" && current.startsWith("#/tournament/") && !isBookmarkRoute(current))
    || (hash === "#/players" && current.startsWith("#/player/"));
  return h("a", { class: `nav-item ${active ? "active" : ""}`, href: hash },
    icon(iconName), h("span", { class: "nav-label", text: label }), badge ? h("span", { class: "nav-badge", text: badge }) : null);
}

function isBookmarkRoute(hash) {
  return state.bookmarks.some((bookmark) => hash === `#/tournament/${bookmark.id}`);
}

function renderSidebar(current = location.hash || defaultRoute()) {
  const unseen = state.following.reduce((sum, entry) => sum + (entry.unseen || 0), 0);
  elements.sidebar.replaceChildren(...[
    navItem("#/following", "Following", "eye", current, unseen || null),
    navItem("#/tournaments", "Tournaments", "trophy", current),
    navItem("#/players", "Players", "person", current),
    state.bookmarks.length ? h("h3", { class: "nav-section", text: "Bookmarks" }) : null,
    state.bookmarks.map((bookmark) => contextMenu(
      h("a", { class: `nav-item small ${current === `#/tournament/${bookmark.id}` ? "active" : ""}`, href: `#/tournament/${bookmark.id}`, title: bookmark.name },
        icon("star", { filled: true }), h("span", { class: "nav-label", text: bookmark.name })),
      () => [
        { label: "Open Standings", symbol: "list.number", action: () => { location.hash = `#/tournament/${bookmark.id}`; } },
        { label: "Remove Bookmark", symbol: "star.slash", action: () => toggleBookmark(bookmark) },
        "-",
        { label: "Open on Chess-Results", symbol: "safari", action: () => openExternal(chessResultsUrl(bookmark.id)) },
      ])),
    h("div", { class: "nav-spacer" }),
    navItem("#/settings", "Settings", "gear", current),
  ].flat().filter(Boolean));
}

// ---------------------------------------------------------------------------
// Startup

document.getElementById("back").append(icon("back"));
document.getElementById("forward").append(icon("forward"));
document.getElementById("back").addEventListener("click", () => history.back());
document.getElementById("forward").addEventListener("click", () => history.forward());

document.addEventListener("keydown", (event) => {
  if (!event.metaKey || event.altKey || event.ctrlKey) return;
  const shortcuts = { "[": () => history.back(), "]": () => history.forward(), 1: "#/following", 2: "#/tournaments", 3: "#/players", ",": "#/settings" };
  const action = shortcuts[event.key];
  if (!action) return;
  event.preventDefault();
  if (typeof action === "function") action();
  else location.hash = action;
});

window.addEventListener("hashchange", route);
subscribe(() => renderSidebar());

await loadState();
scheduleRefresh();
await route();
if (state.following.length) refreshAll().then(() => renderSidebar()).catch(console.error);
