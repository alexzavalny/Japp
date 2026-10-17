// Persistent app state: settings, followed players, bookmarked tournaments and
// a cache of tournament names (the API's detail endpoint is sometimes sparse).
// Uses japp.storage inside JApp Runtime and localStorage in a normal browser.

const storage = window.japp
  ? window.japp.storage
  : {
      async get(key, fallback = null) {
        const json = localStorage.getItem("chess-results." + key);
        return json === null ? fallback : JSON.parse(json);
      },
      async set(key, value) {
        localStorage.setItem("chess-results." + key, JSON.stringify(value));
      },
    };

export const DEFAULT_SETTINGS = {
  baseUrl: "https://transpose-junkie-outlet.ngrok-free.dev",
  apiKey: "",
  country: "LAT",
  refreshMinutes: 10,
  notify: false,
};

const MAX_REMEMBERED_TOURNAMENTS = 400;

export const state = {
  settings: { ...DEFAULT_SETTINGS },
  following: [],     // [{ tournamentId, startNumber, name, tournamentName, points, rank, played, recent, unseen, updatedAt }]
  bookmarks: [],     // [{ id, name, starts_on, ends_on, federation, time_control }]
  tournaments: {},   // id → { name, starts_on, ends_on, federation, time_control }
};

const listeners = new Set();

/** Calls `listener` whenever followed players or bookmarks change. */
export function subscribe(listener) {
  listeners.add(listener);
  return () => listeners.delete(listener);
}

function changed() {
  for (const listener of listeners) listener(state);
}

export async function loadState() {
  const [settings, following, bookmarks, tournaments] = await Promise.all([
    storage.get("settings", {}),
    storage.get("following", []),
    storage.get("bookmarks", []),
    storage.get("tournaments", {}),
  ]);
  state.settings = { ...DEFAULT_SETTINGS, ...settings };
  state.following = Array.isArray(following) ? following : [];
  state.bookmarks = Array.isArray(bookmarks) ? bookmarks : [];
  state.tournaments = tournaments && typeof tournaments === "object" ? tournaments : {};
}

export async function saveSettings(patch) {
  state.settings = { ...state.settings, ...patch };
  await storage.set("settings", state.settings);
  changed();
}

// ---------------------------------------------------------------------------
// Following

export const followKey = (tournamentId, startNumber) => `${tournamentId}:${startNumber}`;

export function findFollowed(tournamentId, startNumber) {
  return state.following.find((entry) => followKey(entry.tournamentId, entry.startNumber) === followKey(tournamentId, startNumber));
}

export async function saveFollowing() {
  await storage.set("following", state.following);
  changed();
}

export async function follow(entry) {
  if (findFollowed(entry.tournamentId, entry.startNumber)) return;
  state.following.push({ unseen: 0, ...entry });
  await saveFollowing();
}

export async function unfollow(tournamentId, startNumber) {
  const key = followKey(tournamentId, startNumber);
  state.following = state.following.filter((entry) => followKey(entry.tournamentId, entry.startNumber) !== key);
  await saveFollowing();
}

// ---------------------------------------------------------------------------
// Bookmarks

export const isBookmarked = (id) => state.bookmarks.some((bookmark) => bookmark.id === String(id));

export async function toggleBookmark(tournament) {
  const id = String(tournament.id);
  if (isBookmarked(id)) {
    state.bookmarks = state.bookmarks.filter((bookmark) => bookmark.id !== id);
  } else {
    const known = state.tournaments[id] || {};
    state.bookmarks.push({ ...known, ...tournament, id, name: tournament.name || known.name || `Tournament ${id}` });
  }
  await storage.set("bookmarks", state.bookmarks);
  changed();
}

// ---------------------------------------------------------------------------
// Tournament names

let saveTimer = null;

/** Remembers what we learn about tournaments (from searches, profiles, standings). */
export function rememberTournaments(list) {
  let updated = false;
  for (const tournament of list) {
    const id = String(tournament.id ?? "");
    if (!id || !tournament.name) continue;
    const previous = state.tournaments[id] || {};
    const next = { ...previous };
    for (const key of ["name", "starts_on", "ends_on", "federation", "time_control"]) {
      if (tournament[key]) next[key] = tournament[key];
    }
    next.seen = Date.now();
    state.tournaments[id] = next;
    updated = true;
  }
  if (!updated) return;
  const ids = Object.keys(state.tournaments);
  if (ids.length > MAX_REMEMBERED_TOURNAMENTS) {
    ids.sort((a, b) => (state.tournaments[a].seen || 0) - (state.tournaments[b].seen || 0));
    for (const id of ids.slice(0, ids.length - MAX_REMEMBERED_TOURNAMENTS)) delete state.tournaments[id];
  }
  clearTimeout(saveTimer);
  saveTimer = setTimeout(() => storage.set("tournaments", state.tournaments).catch(console.error), 500);
}

export function tournamentName(id) {
  return state.tournaments[String(id)]?.name || `Tournament ${id}`;
}
