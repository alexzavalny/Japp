// DOM helpers and formatting. All text from the API is inserted with
// textContent (never innerHTML), so upstream data cannot inject markup.

export function h(tag, props = {}, ...children) {
  const element = document.createElement(tag);
  for (const [key, value] of Object.entries(props || {})) {
    if (value === undefined || value === null || value === false) continue;
    if (key === "class") element.className = value;
    else if (key === "text") element.textContent = value;
    else if (key === "dataset") Object.assign(element.dataset, value);
    else if (key.startsWith("on") && typeof value === "function") element.addEventListener(key.slice(2), value);
    else if (value === true) element.setAttribute(key, "");
    else element.setAttribute(key, value);
  }
  for (const child of children.flat(Infinity)) {
    if (child === null || child === undefined || child === false) continue;
    element.append(child instanceof Node ? child : String(child));
  }
  return element;
}

// Static SVG icons (trusted markup, never data).
const ICONS = {
  back: '<path d="M15 5l-7 7 7 7"/>',
  forward: '<path d="M9 5l7 7-7 7"/>',
  trophy: '<path d="M8 4h8v5a4 4 0 0 1-8 0V4z"/><path d="M8 6H5a3 3 0 0 0 3 4M16 6h3a3 3 0 0 1-3 4M12 13v4M8.5 20h7M10 17h4"/>',
  person: '<circle cx="12" cy="8" r="3.5"/><path d="M5 20c1.2-3.6 3.8-5.5 7-5.5s5.8 1.9 7 5.5"/>',
  star: '<path d="M12 3.8l2.5 5.1 5.6.8-4 3.9.9 5.6-5-2.6-5 2.6.9-5.6-4-3.9 5.6-.8z"/>',
  bell: '<path d="M6 16V11a6 6 0 0 1 12 0v5l1.5 2h-15z"/><path d="M10 20a2 2 0 0 0 4 0"/>',
  gear: '<circle cx="12" cy="12" r="3"/><path d="M12 2.5v3M12 18.5v3M4.2 6.2l2.1 2.1M17.7 15.7l2.1 2.1M2.5 12h3M18.5 12h3M4.2 17.8l2.1-2.1M17.7 8.3l2.1-2.1"/>',
  refresh: '<path d="M20 11a8 8 0 1 0-2.3 5.7"/><path d="M20 4v7h-7"/>',
  external: '<path d="M14 4h6v6M20 4l-9 9"/><path d="M18 14v5a1 1 0 0 1-1 1H5a1 1 0 0 1-1-1V7a1 1 0 0 1 1-1h5"/>',
  search: '<circle cx="11" cy="11" r="6.5"/><path d="M16 16l4.5 4.5"/>',
  close: '<path d="M6 6l12 12M18 6L6 18"/>',
  eye: '<path d="M2.5 12S6 5.5 12 5.5 21.5 12 21.5 12 18 18.5 12 18.5 2.5 12 2.5 12z"/><circle cx="12" cy="12" r="3"/>',
};

export function icon(name, { filled = false } = {}) {
  const span = h("span", { class: "icon", "aria-hidden": "true" });
  span.innerHTML = `<svg viewBox="0 0 24 24" fill="${filled ? "currentColor" : "none"}" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round">${ICONS[name] || ""}</svg>`;
  return span;
}

export function button(label, { icon: iconName, onclick, kind = "", title, filled = false, disabled = false } = {}) {
  return h(
    "button",
    { type: "button", class: `button ${kind}`.trim(), onclick, title, disabled, "aria-label": label || title },
    iconName ? icon(iconName, { filled }) : null,
    label ? h("span", { text: label }) : null
  );
}

export function link(label, href, { iconName = "external" } = {}) {
  return h("a", { class: "button link", href, target: "_blank", rel: "noopener" }, h("span", { text: label }), icon(iconName));
}

/** The macOS spinning progress indicator: twelve fading spokes. */
export function spinner(label = "Loading…") {
  const spokes = h("div", { class: "spinner", role: "progressbar", "aria-label": label });
  for (let index = 0; index < 12; index++) spokes.append(h("i", { style: `--i: ${index}` }));
  return h("div", { class: "loading" }, spokes, h("span", { text: label }));
}

/** Opens a web page in the user's browser (JApp never navigates the app window away). */
export function openExternal(url) {
  window.open(url, "_blank");
}

/**
 * A native context menu (japp.menu.popup) on right-click. `items()` is called each
 * time and returns entries { label, action, symbol?, enabled?, checked? } or "-".
 * The element is outlined while its menu is open, as macOS lists do.
 */
export function contextMenu(element, items) {
  element.addEventListener("contextmenu", async (event) => {
    if (!window.japp?.menu) return;
    event.preventDefault();
    event.stopPropagation();
    const actions = new Map();
    const spec = items().filter(Boolean).map((item, index) => {
      if (item === "-") return "-";
      actions.set(String(index), item.action);
      return { id: String(index), label: item.label, symbol: item.symbol, enabled: item.enabled !== false, checked: item.checked };
    });
    element.classList.add("menu-target");
    try {
      const chosen = await japp.menu.popup(spec, { x: event.clientX, y: event.clientY });
      if (chosen !== null) await actions.get(chosen)?.();
    } finally {
      element.classList.remove("menu-target");
    }
  });
  return element;
}

export function emptyState(title, message, ...actions) {
  return h("div", { class: "empty" }, h("h2", { text: title }), message ? h("p", { text: message }) : null, actions.length ? h("div", { class: "empty-actions" }, actions) : null);
}

export function errorBox(error, retry) {
  return h(
    "div",
    { class: "error-box", role: "alert" },
    h("strong", { text: error?.network ? "Can't reach the API" : "Something went wrong" }),
    h("p", { text: error?.message || String(error) }),
    retry ? button("Try Again", { onclick: retry }) : null
  );
}

export function debounce(fn, ms = 300) {
  let timer;
  return (...args) => {
    clearTimeout(timer);
    timer = setTimeout(() => fn(...args), ms);
  };
}

// ---------------------------------------------------------------------------
// Formatting

const dayFormat = new Intl.DateTimeFormat(undefined, { day: "numeric", month: "short" });
const fullFormat = new Intl.DateTimeFormat(undefined, { day: "numeric", month: "short", year: "numeric" });

function parseDate(value) {
  if (!value) return null;
  const date = new Date(`${value}T00:00:00`);
  return Number.isNaN(date.getTime()) ? null : date;
}

export function formatDateRange(start, end) {
  const from = parseDate(start);
  const to = parseDate(end);
  if (!from && !to) return "";
  if (!from || !to || from.getTime() === to.getTime()) return fullFormat.format(from || to);
  if (from.getFullYear() === to.getFullYear()) return `${dayFormat.format(from)} – ${fullFormat.format(to)}`;
  return `${fullFormat.format(from)} – ${fullFormat.format(to)}`;
}

/** "ongoing", "upcoming" or "finished" relative to today. */
export function tournamentStatus(start, end) {
  const today = isoDate(new Date());
  if (start && start > today) return "upcoming";
  if (end && end < today) return "finished";
  return "ongoing";
}

export function isoDate(date) {
  const local = new Date(date.getTime() - date.getTimezoneOffset() * 60_000);
  return local.toISOString().slice(0, 10);
}

export function addDays(date, days) {
  const copy = new Date(date);
  copy.setDate(copy.getDate() + days);
  return copy;
}

export function timeAgo(value) {
  if (!value) return "";
  const time = typeof value === "number" ? value : Date.parse(value);
  if (Number.isNaN(time)) return "";
  const seconds = Math.max(0, Math.round((Date.now() - time) / 1000));
  if (seconds < 45) return "just now";
  const minutes = Math.round(seconds / 60);
  if (minutes < 60) return `${minutes} min ago`;
  const hours = Math.round(minutes / 60);
  if (hours < 24) return `${hours} h ago`;
  return `${Math.round(hours / 24)} d ago`;
}

/** 6.5 → "6½", 7 → "7", null → "–". */
export function formatPoints(points, fallback) {
  if (points === null || points === undefined || Number.isNaN(Number(points))) return fallback || "–";
  const whole = Math.floor(points);
  const half = Math.abs(points - whole - 0.5) < 1e-9;
  if (half) return whole === 0 ? "½" : `${whole}½`;
  return String(points);
}

/**
 * Classifies a free-text time control using FIDE's rule: base minutes plus
 * 60 × increment seconds (i.e. base + increment, in minutes).
 */
export function timeControlCategory(text, name = "") {
  if (!text) {
    // No time control published: fall back to words in the tournament name.
    const lower = name.toLowerCase();
    if (/blitz|blic|zibens/.test(lower)) return "Blitz";
    if (/rapid|ātr/.test(lower)) return "Rapid";
    if (/classic|klasisk/.test(lower)) return "Classical";
    return null;
  }
  const lower = text.toLowerCase();
  if (/blitz|zibens/.test(lower)) return "Blitz";
  if (/rapid|ātr|atr[aā]/.test(lower)) return "Rapid";
  if (/classic|klasisk|standard/.test(lower)) return "Classical";
  const numbers = lower.match(/\d+(?:[.,]\d+)?/g);
  if (!numbers) return null;
  let base = parseFloat(numbers[0].replace(",", "."));
  if (/^\s*\d+\s*h/.test(lower)) base *= 60;
  const increment = numbers[1] ? parseFloat(numbers[1].replace(",", ".")) : 0;
  const total = base + increment;
  if (total <= 10) return "Blitz";
  if (total < 60) return "Rapid";
  return "Classical";
}

const RESULT_TEXT = { win: "1", draw: "½", loss: "0", forfeit_win: "+", forfeit_loss: "−", bye: "bye", unplayed: "–" };

/** Badge for one game's result, coloured by outcome. */
export function resultBadge(game) {
  const kind = game.result_kind || "unknown";
  // An unknown kind with a raw value usually means Chess-Results used a layout the
  // API cannot read yet; show "?" and keep the raw text in the tooltip.
  const text = RESULT_TEXT[kind] ?? (game.result || "?");
  const title = kind === "unknown" && game.source_result_text ? `Result not available (Chess-Results shows “${game.source_result_text}”)` : {
    win: "Win", draw: "Draw", loss: "Loss", forfeit_win: "Win by forfeit", forfeit_loss: "Loss by forfeit",
    bye: "Bye", unplayed: "Not played", unknown: "Result not available",
  }[kind];
  return h("span", { class: `result result-${kind}`, title }, text);
}

export function colorDot(color) {
  if (color !== "white" && color !== "black") return h("span", { class: "dot dot-none", title: "No colour" });
  return h("span", { class: `dot dot-${color}`, title: color === "white" ? "White" : "Black" });
}

/** Whether a game has a known outcome (used to detect new results). */
export function isDecided(game) {
  return ["win", "draw", "loss", "forfeit_win", "forfeit_loss", "bye"].includes(game.result_kind) || game.result !== null && game.result !== undefined;
}

export function describeGame(game) {
  const outcome = { win: "won", draw: "drew", loss: "lost", forfeit_win: "won by forfeit", forfeit_loss: "lost by forfeit", bye: "had a bye" }[game.result_kind] || `scored ${game.result ?? game.source_result_text ?? "?"}`;
  const opponent = game.opponent_name ? ` against ${game.opponent_name}` : "";
  return `Round ${game.round}: ${outcome}${game.result_kind === "bye" ? "" : opponent}`;
}

export function titleBadge(title) {
  return title ? h("span", { class: "title-badge", text: title }) : null;
}

export function metaLine(meta) {
  if (!meta) return null;
  const parts = [`Updated ${timeAgo(meta.fetched_at)}`];
  if (meta.stale) parts.push("showing older data (Chess-Results unavailable)");
  return h("p", { class: `meta-line ${meta.stale ? "stale" : ""}`, text: parts.join(" · ") });
}
