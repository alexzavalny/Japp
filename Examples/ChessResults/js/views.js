// The app's screens. Each view receives a `page` with:
//   page.title(title, subtitle)   page.actions(...nodes)   page.body (element)
//   page.navigate(hash)           page.isCurrent()          page.memory (survives navigation)

import { api, chessResultsUrl, request } from "./api.js";
import { markSeen, refreshAll, scheduleRefresh, summarize } from "./following.js";
import {
  DEFAULT_SETTINGS, findFollowed, follow, isBookmarked, rememberTournaments, saveSettings, state,
  toggleBookmark, tournamentName, unfollow,
} from "./store.js";
import {
  addDays, button, colorDot, contextMenu, debounce, emptyState, errorBox, formatDateRange, formatPoints, h, icon, isoDate,
  link, metaLine, openExternal, resultBadge, spinner, timeAgo, timeControlCategory, titleBadge, tournamentStatus,
} from "./ui.js";

const FEDERATIONS = [
  "LAT", "LTU", "EST", "FIN", "SWE", "NOR", "DEN", "ISL", "POL", "GER", "UKR", "ENG", "SCO", "IRL", "FRA", "ESP", "POR",
  "ITA", "NED", "BEL", "LUX", "SUI", "AUT", "CZE", "SVK", "HUN", "ROU", "BUL", "SRB", "CRO", "SLO", "BIH", "MNE", "MKD",
  "GRE", "TUR", "CYP", "ISR", "GEO", "ARM", "AZE", "KAZ", "UZB", "IND", "CHN", "USA", "CAN", "BRA", "ARG", "AUS",
];

/** Runs `load`, showing a spinner and an error box with retry. Returns null if navigation moved on. */
async function loadInto(page, container, load, label) {
  container.replaceChildren(spinner(label));
  try {
    const value = await load();
    if (!page.isCurrent()) return null;
    container.replaceChildren();
    return value;
  } catch (error) {
    if (page.isCurrent()) container.replaceChildren(errorBox(error, () => page.reload()));
    console.error(error);
    return null;
  }
}

function card(...children) {
  return h("div", { class: "card" }, children);
}

function stat(label, value) {
  return h("div", { class: "stat" }, h("span", { class: "stat-value", text: value ?? "–" }), h("span", { class: "stat-label", text: label }));
}

/**
 * The tournament detail endpoint cannot read every Chess-Results layout, so a
 * tournament may arrive without a name. The player index knows the names of
 * tournaments its players appeared in; ask it via any participant.
 */
async function resolveTournamentName(tournamentId, playerKey) {
  if (state.tournaments[tournamentId]?.name || !playerKey) return state.tournaments[tournamentId]?.name || null;
  try {
    const profile = (await api.playerProfile(playerKey, { ttl: 10 * 60_000 })).data;
    const appearance = (profile.appearances || []).find((item) => String(item.tournament_id) === String(tournamentId));
    if (appearance?.tournament_name) {
      rememberTournaments([{ id: tournamentId, name: appearance.tournament_name, ends_on: appearance.ends_on }]);
      return appearance.tournament_name;
    }
  } catch (error) {
    console.warn("Could not resolve the tournament name:", error.message);
  }
  return null;
}

// ---------------------------------------------------------------------------
// Tournaments search

function presetRange(name) {
  const today = new Date();
  switch (name) {
    case "past":
      return [addDays(today, -31), today];
    case "upcoming":
      return [today, addDays(today, 90)];
    case "year":
      return [new Date(today.getFullYear(), 0, 1), new Date(today.getFullYear(), 11, 31)];
    default:
      return [addDays(today, -7), addDays(today, 45)];
  }
}

export async function tournamentsView(page) {
  page.title("Tournaments", "Search Chess-Results by federation and end date");
  const memory = (page.memory.tournaments ||= (() => {
    const [from, to] = presetRange("current");
    return { country: state.settings.country, from: isoDate(from), to: isoDate(to), q: "", timeControl: "", category: "All", preset: "current", results: null };
  })());

  const country = h("input", { class: "field country", value: memory.country, maxlength: 3, list: "federations", "aria-label": "Federation", title: "Three-letter federation code, or - for all countries", spellcheck: "false" });
  const from = h("input", { class: "field", type: "date", value: memory.from, "aria-label": "Ends after" });
  const to = h("input", { class: "field", type: "date", value: memory.to, "aria-label": "Ends before" });
  const query = h("input", { class: "field grow", type: "search", value: memory.q, placeholder: "Tournament name contains…", "aria-label": "Name" });
  const results = h("div", { class: "results" });

  const presets = h("div", { class: "segmented" },
    [["current", "Current"], ["upcoming", "Upcoming"], ["past", "Past month"], ["year", "This year"]].map(([key, label]) =>
      h("button", {
        type: "button",
        class: memory.preset === key ? "active" : "",
        onclick: (event) => {
          const [start, end] = presetRange(key);
          from.value = isoDate(start);
          to.value = isoDate(end);
          memory.preset = key;
          for (const segment of presets.children) segment.classList.toggle("active", segment === event.currentTarget);
          search();
        },
      }, label)));
  const clearPreset = () => {
    memory.preset = null;
    for (const segment of presets.children) segment.classList.remove("active");
  };
  from.addEventListener("change", clearPreset);
  to.addEventListener("change", clearPreset);

  const categories = h("div", { class: "chips" },
    ["All", "Blitz", "Rapid", "Classical"].map((category) =>
      h("button", {
        type: "button",
        class: `chip ${memory.category === category ? "active" : ""}`,
        onclick: (event) => {
          memory.category = category;
          for (const chip of categories.children) chip.classList.toggle("active", chip === event.currentTarget);
          renderResults();
        },
      }, category)));

  const form = h("form", { class: "filter-bar", onsubmit: (event) => { event.preventDefault(); search(); } },
    h("label", { class: "inline-label" }, "Federation", country),
    h("label", { class: "inline-label" }, "Ends", from, h("span", { class: "muted", text: "to" }), to),
    query,
    button("Search", { kind: "primary", icon: "search", onclick: () => search() }));
  page.body.append(
    form,
    h("div", { class: "filter-row" }, presets, categories),
    h("datalist", { id: "federations" }, [h("option", { value: "-", label: "All countries" }), ...FEDERATIONS.map((code) => h("option", { value: code }))]),
    results);

  function renderResults() {
    if (!memory.results) return;
    const list = memory.results.filter((tournament) => memory.category === "All" || timeControlCategory(tournament.time_control, tournament.name) === memory.category);
    if (!list.length) {
      results.replaceChildren(emptyState("No tournaments found", "Try a wider date range, another federation (“-” searches all), or a different category."));
      return;
    }
    const groups = { ongoing: [], upcoming: [], finished: [] };
    for (const tournament of list) groups[tournamentStatus(tournament.starts_on, tournament.ends_on)].push(tournament);
    groups.ongoing.sort((a, b) => (a.ends_on || "").localeCompare(b.ends_on || ""));
    groups.upcoming.sort((a, b) => (a.starts_on || "").localeCompare(b.starts_on || ""));
    groups.finished.sort((a, b) => (b.ends_on || "").localeCompare(a.ends_on || ""));
    results.replaceChildren(
      h("p", { class: "count", text: `${list.length} tournament${list.length === 1 ? "" : "s"}` }),
      ...[["ongoing", "In progress"], ["upcoming", "Upcoming"], ["finished", "Finished"]]
        .filter(([key]) => groups[key].length)
        .map(([key, label]) => h("section", { class: "group" },
          h("h2", { class: "group-title" }, label, h("span", { class: "badge", text: groups[key].length })),
          h("ul", { class: "list" }, groups[key].map((tournament) => tournamentRow(page, tournament))))));
  }

  async function search() {
    memory.country = country.value.trim().toUpperCase() || "-";
    memory.from = from.value;
    memory.to = to.value;
    memory.q = query.value.trim();
    country.value = memory.country;
    const body = await loadInto(page, results, () => api.searchTournaments({
      country: memory.country, end_from: memory.from, end_to: memory.to, q: memory.q,
    }), "Searching Chess-Results…");
    if (!body) return;
    memory.results = body.data || [];
    rememberTournaments(memory.results);
    renderResults();
  }

  if (memory.results) renderResults();
  else search();
}

function tournamentRow(page, tournament) {
  const category = timeControlCategory(tournament.time_control, tournament.name);
  const star = h("button", {
    type: "button",
    class: `star ${isBookmarked(tournament.id) ? "on" : ""}`,
    title: "Bookmark",
    "aria-label": "Bookmark",
    onclick: async (event) => {
      event.stopPropagation();
      await toggleBookmark(tournament);
      star.classList.toggle("on", isBookmarked(tournament.id));
      star.replaceChildren(icon("star", { filled: isBookmarked(tournament.id) }));
    },
  }, icon("star", { filled: isBookmarked(tournament.id) }));
  const open = () => page.navigate(`#/tournament/${tournament.id}`);
  const row = h("li", { class: "row clickable", tabindex: "0", onclick: open, onkeydown: (event) => { if (event.key === "Enter") open(); } },
    star,
    h("div", { class: "row-main" },
      h("div", { class: "row-title", text: tournament.name || `Tournament ${tournament.id}` }),
      h("div", { class: "row-sub" },
        h("span", { text: formatDateRange(tournament.starts_on, tournament.ends_on) }),
        tournament.time_control ? h("span", { class: "muted", text: tournament.time_control }) : null)),
    category ? h("span", { class: `tag tag-${category.toLowerCase()}`, text: category }) : null,
    tournament.federation ? h("span", { class: "fed", text: tournament.federation }) : null);
  return contextMenu(row, () => [
    { label: "Open Standings", symbol: "list.number", action: open },
    isBookmarked(tournament.id)
      ? { label: "Remove Bookmark", symbol: "star.slash", action: () => star.click() }
      : { label: "Bookmark", symbol: "star", action: () => star.click() },
    "-",
    { label: "Open on Chess-Results", symbol: "safari", action: () => openExternal(chessResultsUrl(tournament.id)) },
  ]);
}

// ---------------------------------------------------------------------------
// Tournament: standings

export async function tournamentView(page, id) {
  const known = state.tournaments[id] || {};
  page.title(tournamentName(id), formatDateRange(known.starts_on, known.ends_on));
  const memory = (page.memory.standings ||= {});
  const options = (memory[id] ||= { round: "", filter: "" });

  const bookmark = button(isBookmarked(id) ? "Bookmarked" : "Bookmark", {
    icon: "star", filled: isBookmarked(id),
    onclick: async () => {
      await toggleBookmark({ id, ...state.tournaments[id], name: tournamentName(id) });
      page.reload();
    },
  });
  page.actions(bookmark, button("", { icon: "refresh", title: "Refresh from Chess-Results", onclick: () => render(true) }), link("Chess-Results", chessResultsUrl(id)));

  const content = h("div");
  page.body.append(content);

  async function render(refresh = false) {
    const loaded = await loadInto(page, content, () => Promise.all([
      api.tournament(id, { refresh }).catch(() => null),
      api.standings(id, { round: options.round }, { refresh }),
    ]), refresh ? "Refreshing from Chess-Results…" : "Loading standings…");
    if (!loaded) return;
    const [detailBody, standingsBody] = loaded;
    const detail = detailBody?.data || {};
    if (detail.name) {
      rememberTournaments([{ ...detail, id }]);
      page.title(detail.name, formatDateRange(detail.starts_on, detail.ends_on));
    }
    const standings = standingsBody.data;
    if (!detail.name) {
      const keyed = (standings.standings || []).find((row) => row.player_key);
      resolveTournamentName(id, keyed?.player_key).then((name) => {
        if (name && page.isCurrent()) page.title(name, formatDateRange(state.tournaments[id]?.starts_on, state.tournaments[id]?.ends_on));
      });
    }

    const facts = [
      detail.federation || known.federation,
      detail.time_control || known.time_control,
      detail.tournament_type,
      detail.round_count ? `${detail.round_count} rounds` : null,
    ].filter(Boolean);
    const rounds = detail.available_standing_rounds || [];
    const roundPicker = rounds.length
      ? h("select", { class: "field", "aria-label": "Round", onchange: (event) => { options.round = event.target.value; render(); } },
          h("option", { value: "", text: "Latest" }),
          rounds.map((round) => h("option", { value: round, selected: String(round) === String(options.round), text: `After round ${round}` })))
      : null;
    const filter = h("input", { class: "field grow", type: "search", placeholder: "Filter players…", value: options.filter, "aria-label": "Filter players" });

    const tableHost = h("div", { class: "table-host" });
    const renderTable = () => {
      options.filter = filter.value;
      tableHost.replaceChildren(standingsTable(page, id, standings.standings || [], filter.value.trim().toLowerCase()));
    };
    filter.addEventListener("input", debounce(renderTable, 150));

    content.append(
      h("div", { class: "summary" },
        h("div", {},
          h("h2", { class: "heading", text: standings.heading || "Standings" }),
          facts.length ? h("p", { class: "muted", text: facts.join(" · ") }) : null),
        h("div", { class: "summary-controls" }, roundPicker, filter)),
      tableHost,
      metaLine(standingsBody.meta));
    renderTable();
  }
  await render();
}

function standingsTable(page, tournamentId, rows, filter) {
  if (!rows.length) return emptyState("No standings yet", "Chess-Results has not published standings for this tournament, or its layout is not supported yet.");
  const matches = rows.filter((row) => !filter || [row.name, row.club, row.federation, row.title].some((value) => value && value.toLowerCase().includes(filter)));
  if (!matches.length) return emptyState("No matching players");
  const tieBreaks = [...new Set(rows.flatMap((row) => Object.keys(row.tie_breaks || {})))].sort();
  const showClub = rows.some((row) => row.club);
  const showGroup = rows.some((row) => row.group);
  const showChange = rows.some((row) => row.rating_change !== null && row.rating_change !== undefined);

  const head = h("tr", {},
    h("th", { class: "num", text: "Rk" }), h("th", { class: "num", text: "SNo" }), h("th", { text: "Name" }),
    h("th", { text: "Fed" }), h("th", { class: "num", text: "Rtg" }),
    showChange ? h("th", { class: "num", text: "±" }) : null,
    showClub ? h("th", { text: "Club" }) : null,
    showGroup ? h("th", { text: "Group" }) : null,
    h("th", { class: "num", text: "Pts" }),
    tieBreaks.map((key) => h("th", { class: "num tb", text: key.toUpperCase() })));

  const body = matches.map((row) => {
    const followed = findFollowed(tournamentId, row.start_number);
    const open = () => row.start_number && page.navigate(`#/tournament/${tournamentId}/player/${row.start_number}`);
    const tr = h("tr", { class: `clickable ${followed ? "followed" : ""}`, tabindex: "0", onclick: open, onkeydown: (event) => { if (event.key === "Enter") open(); } },
      h("td", { class: "num strong", text: row.rank ?? "" }),
      h("td", { class: "num muted", text: row.start_number ?? "" }),
      h("td", {}, h("span", { class: "name" }, titleBadge(row.title), h("span", { text: row.name }), followed ? icon("eye") : null)),
      h("td", { class: "fed", text: row.federation || "" }),
      h("td", { class: "num", text: row.rating || "" }),
      showChange ? h("td", { class: `num ${row.rating_change > 0 ? "up" : row.rating_change < 0 ? "down" : ""}`, text: row.rating_change ?? "" }) : null,
      showClub ? h("td", { class: "muted", text: row.club || "" }) : null,
      showGroup ? h("td", { text: row.group || "" }) : null,
      h("td", { class: "num strong", text: formatPoints(row.points, row.points_text) }),
      tieBreaks.map((key) => h("td", { class: "num tb muted", text: row.tie_breaks?.[key] ?? "" })));
    if (!row.start_number) return tr;
    return contextMenu(tr, () => {
      const following = Boolean(findFollowed(tournamentId, row.start_number));
      return [
        { label: "Show Results", symbol: "list.bullet.rectangle", action: open },
        following
          ? { label: "Stop Following", symbol: "eye.slash", action: async () => { await unfollow(tournamentId, row.start_number); page.reload(); } }
          : { label: "Follow", symbol: "eye", action: async () => { await followPlayer(tournamentId, row.start_number, row.name); page.reload(); } },
        "-",
        { label: "Open on Chess-Results", symbol: "safari", action: () => openExternal(chessResultsUrl(tournamentId, row.start_number)) },
      ];
    });
  });
  return h("table", { class: "table" }, h("thead", {}, head), h("tbody", {}, body));
}

/** Follows a player from a list, fetching their results for the summary. */
async function followPlayer(tournamentId, startNumber, name) {
  const results = (await api.results(tournamentId, startNumber)).data;
  await follow({
    tournamentId: String(tournamentId), startNumber: String(startNumber), tournamentName: tournamentName(tournamentId),
    ...summarize(results), name: results.player?.name || name, updatedAt: Date.now(),
  });
}

// ---------------------------------------------------------------------------
// One player's results in a tournament

export async function playerResultsView(page, tournamentId, startNumber) {
  page.title("Player", tournamentName(tournamentId));
  const content = h("div");
  page.body.append(content);

  async function render(refresh = false) {
    const loaded = await loadInto(page, content, () => Promise.all([
      api.player(tournamentId, startNumber, { refresh }).catch(() => null),
      api.results(tournamentId, startNumber, { refresh }),
    ]), "Loading results…");
    if (!loaded) return;
    const [playerBody, resultsBody] = loaded;
    const player = playerBody?.data || {};
    const results = resultsBody.data;
    const name = player.name || results.player?.name || `Player ${startNumber}`;
    page.title(name, tournamentName(tournamentId));
    resolveTournamentName(tournamentId, player.player_key || results.player?.player_key).then((resolved) => {
      if (resolved && page.isCurrent()) page.title(name, resolved);
    });
    if (findFollowed(tournamentId, startNumber)) markSeen(tournamentId, startNumber, results).catch(console.error);

    const followed = Boolean(findFollowed(tournamentId, startNumber));
    page.actions(
      button(followed ? "Following" : "Follow", {
        icon: "eye", kind: followed ? "" : "primary",
        onclick: async () => {
          if (findFollowed(tournamentId, startNumber)) {
            await unfollow(tournamentId, startNumber);
          } else {
            await follow({ tournamentId: String(tournamentId), startNumber: String(startNumber), tournamentName: tournamentName(tournamentId), ...summarize(results), updatedAt: Date.now() });
          }
          render();
        },
      }),
      (player.player_key || results.player?.player_key)
        ? button("Profile", { icon: "person", onclick: () => page.navigate(`#/player/${encodeURIComponent(player.player_key || results.player.player_key)}`) })
        : null,
      button("", { icon: "refresh", title: "Refresh from Chess-Results", onclick: () => render(true) }),
      link("Chess-Results", chessResultsUrl(tournamentId, startNumber)));

    const games = results.games || [];
    const tally = { win: 0, draw: 0, loss: 0 };
    for (const game of games) {
      if (game.result_kind === "win" || game.result_kind === "forfeit_win") tally.win++;
      else if (game.result_kind === "draw") tally.draw++;
      else if (game.result_kind === "loss" || game.result_kind === "forfeit_loss") tally.loss++;
    }
    const fideId = player.fide_id || results.player?.fide_id;
    const details = [
      player.federation,
      player.club,
      player.birth_year ? `born ${player.birth_year}` : null,
    ].filter(Boolean).join(" · ");

    content.append(
      card(
        h("div", { class: "player-head" },
          h("div", {},
            h("h2", { class: "player-name", "data-selectable": true }, titleBadge(player.title), h("span", { text: name })),
            details ? h("p", { class: "muted", "data-selectable": true, text: details }) : null,
            fideId ? h("a", { class: "subtle-link", href: `https://ratings.fide.com/profile/${encodeURIComponent(fideId)}`, target: "_blank", text: `FIDE ${fideId}` }) : null),
          h("div", { class: "stats" },
            stat("Rank", player.rank ?? results.player?.rank),
            stat("Points", formatPoints(player.points ?? results.player?.points)),
            stat("Rating", player.rating || "–"),
            stat("Performance", player.performance_rating || "–"),
            player.rating_change !== null && player.rating_change !== undefined ? stat("Rating ±", player.rating_change > 0 ? `+${player.rating_change}` : player.rating_change) : null,
            stat("W / D / L", `${tally.win} / ${tally.draw} / ${tally.loss}`)))),
      gamesTable(page, tournamentId, games),
      metaLine(resultsBody.meta));
  }
  await render();
}

function gamesTable(page, tournamentId, games) {
  if (!games.length) return emptyState("No games yet", "Results appear here once the first round is paired.");
  const showBoard = games.some((game) => game.board);
  const showOpponentPoints = games.some((game) => game.opponent_points !== null && game.opponent_points !== undefined);
  const head = h("tr", {},
    h("th", { class: "num", text: "Rd" }), showBoard ? h("th", { class: "num", text: "Bd" }) : null, h("th", { text: "" }),
    h("th", { text: "Opponent" }), h("th", { class: "num", text: "Rtg" }), h("th", { text: "Fed" }),
    showOpponentPoints ? h("th", { class: "num", text: "Pts" }) : null, h("th", { class: "num", text: "Result" }));
  const rows = games.map((game) => {
    const opponentKnown = Boolean(game.opponent_start_number);
    const open = () => opponentKnown && page.navigate(`#/tournament/${tournamentId}/player/${game.opponent_start_number}`);
    const opponent = game.opponent_name || (game.result_kind === "bye" ? "Bye" : game.source_result_text && !game.opponent_name ? "—" : "");
    const tr = h("tr", { class: opponentKnown ? "clickable" : "", onclick: open, tabindex: opponentKnown ? "0" : null, onkeydown: (event) => { if (event.key === "Enter") open(); } },
      h("td", { class: "num strong", text: game.round }),
      showBoard ? h("td", { class: "num muted", text: game.board ?? "" }) : null,
      h("td", { class: "color" }, colorDot(game.color)),
      h("td", {}, h("span", { class: "name" }, titleBadge(game.opponent_title), h("span", { text: opponent }))),
      h("td", { class: "num", text: game.opponent_rating || "" }),
      h("td", { class: "fed", text: game.opponent_federation && game.opponent_federation !== "0" ? game.opponent_federation : "" }),
      showOpponentPoints ? h("td", { class: "num muted", text: formatPoints(game.opponent_points) }) : null,
      h("td", { class: "num" }, resultBadge(game)));
    if (!opponentKnown) return tr;
    return contextMenu(tr, () => [
      { label: `Show ${opponent || "Opponent"}’s Results`, symbol: "list.bullet.rectangle", action: open },
      { label: "Open on Chess-Results", symbol: "safari", action: () => openExternal(chessResultsUrl(tournamentId, game.opponent_start_number)) },
    ]);
  });
  return h("table", { class: "table games" }, h("thead", {}, head), h("tbody", {}, rows));
}

// ---------------------------------------------------------------------------
// Player index search

export async function playersView(page) {
  page.title("Players", "Players seen in tournaments the API has read");
  const memory = (page.memory.players ||= { query: "", results: null });
  const input = h("input", { class: "field grow", type: "search", placeholder: "Search by name, e.g. Zavalnijs", value: memory.query, "aria-label": "Player name", autofocus: true });
  const results = h("div", { class: "results" });
  page.body.append(h("div", { class: "filter-bar" }, icon("search"), input), results);

  const show = () => {
    if (!memory.results) {
      results.replaceChildren(emptyState("Find a player", "Type at least two letters of a name. The index covers players from tournaments that have been opened through the API."));
      return;
    }
    if (!memory.results.length) {
      results.replaceChildren(emptyState("No players found", "Only players from tournaments the API has already read are indexed. Open a tournament first, then search again."));
      return;
    }
    results.replaceChildren(h("ul", { class: "list" }, memory.results.map((player) =>
      contextMenu(h("li", { class: "row clickable", tabindex: "0", onclick: () => page.navigate(`#/player/${encodeURIComponent(player.player_key)}`), onkeydown: (event) => { if (event.key === "Enter") page.navigate(`#/player/${encodeURIComponent(player.player_key)}`); } },
        h("div", { class: "avatar", text: initials(player.name) }),
        h("div", { class: "row-main" },
          h("div", { class: "row-title", text: player.name }),
          h("div", { class: "row-sub" },
            player.fide_id ? h("span", { text: `FIDE ${player.fide_id}` }) : null,
            player.club ? h("span", { class: "muted", text: player.club }) : null,
            h("span", { class: "muted", text: `${player.tournament_count} tournament${player.tournament_count === 1 ? "" : "s"}` }),
            player.last_seen_at ? h("span", { class: "muted", text: `last ${formatDateRange(player.last_seen_at.slice(0, 10))}` }) : null)),
        player.federation ? h("span", { class: "fed", text: player.federation }) : null), () => [
        { label: "Show Profile", symbol: "person.crop.circle", action: () => page.navigate(`#/player/${encodeURIComponent(player.player_key)}`) },
        player.fide_id ? "-" : null,
        player.fide_id ? { label: "Open FIDE Profile", symbol: "safari", action: () => openExternal(`https://ratings.fide.com/profile/${encodeURIComponent(player.fide_id)}`) } : null,
      ]))));
  };

  const search = debounce(async () => {
    memory.query = input.value.trim();
    if (memory.query.length < 2) {
      memory.results = null;
      show();
      return;
    }
    const body = await loadInto(page, results, () => request("/api/v1/players", { q: memory.query, limit: 50 }), "Searching…");
    if (!body) return;
    memory.results = body.data || [];
    show();
  }, 300);
  input.addEventListener("input", search);
  show();
  setTimeout(() => input.focus(), 0);
}

function initials(name = "") {
  const parts = name.replace(",", "").split(/\s+/).filter(Boolean);
  return ((parts[1]?.[0] || "") + (parts[0]?.[0] || "")).toUpperCase() || "?";
}

// ---------------------------------------------------------------------------
// Player profile (from the index)

export async function playerProfileView(page, key) {
  page.title("Player", "");
  const content = h("div");
  page.body.append(content);
  const body = await loadInto(page, content, () => api.playerProfile(key), "Loading player…");
  if (!body) return;
  const player = body.data;
  page.title(player.name, [player.federation, player.club].filter(Boolean).join(" · "));
  const when = (appearance) => appearance.ends_on || appearance.seen_at?.slice(0, 10) || "";
  const appearances = [...(player.appearances || [])].sort((a, b) => when(b).localeCompare(when(a)));
  rememberTournaments(appearances.map((appearance) => ({ id: appearance.tournament_id, name: appearance.tournament_name, ends_on: appearance.ends_on })));
  if (player.fide_id) page.actions(link("FIDE profile", `https://ratings.fide.com/profile/${encodeURIComponent(player.fide_id)}`));

  content.append(
    card(h("div", { class: "player-head" },
      h("div", {},
        h("h2", { class: "player-name", "data-selectable": true, text: player.name }),
        h("p", { class: "muted", "data-selectable": true, text: [player.fide_id ? `FIDE ${player.fide_id}` : null, identityLabel(player.identity_confidence)].filter(Boolean).join(" · ") })),
      h("div", { class: "stats" }, stat("Tournaments", player.tournament_count), stat("Last seen", player.last_seen_at ? timeAgo(player.last_seen_at) : "–")))),
    h("h2", { class: "section-title", text: "Tournaments" }),
    appearances.length
      ? h("ul", { class: "list" }, appearances.map((appearance) => {
          const open = () => page.navigate(`#/tournament/${appearance.tournament_id}/player/${appearance.start_number}`);
          const followed = findFollowed(appearance.tournament_id, appearance.start_number);
          const row = h("li", { class: "row clickable", tabindex: "0", onclick: open, onkeydown: (event) => { if (event.key === "Enter") open(); } },
            h("div", { class: "row-main" },
              h("div", { class: "row-title", text: appearance.tournament_name || tournamentName(appearance.tournament_id) }),
              h("div", { class: "row-sub" },
                when(appearance) ? h("span", { text: formatDateRange(when(appearance)) }) : null,
                h("span", { class: "muted", text: `No. ${appearance.start_number}` }),
                appearance.rating ? h("span", { class: "muted", text: `Rating ${appearance.rating}` }) : null,
                appearance.club ? h("span", { class: "muted", text: appearance.club }) : null)),
            followed ? h("span", { class: "tag", text: "Following" }) : null);
          return contextMenu(row, () => [
            { label: "Show Results", symbol: "list.bullet.rectangle", action: open },
            { label: "Open Standings", symbol: "list.number", action: () => page.navigate(`#/tournament/${appearance.tournament_id}`) },
            "-",
            { label: "Open on Chess-Results", symbol: "safari", action: () => openExternal(chessResultsUrl(appearance.tournament_id, appearance.start_number)) },
          ]);
        }))
      : emptyState("No tournaments", ""),
    metaLine(body.meta));
}

function identityLabel(confidence) {
  return { fide: "identified by FIDE ID", name_federation: "matched by name and federation", tournament_only: "single tournament" }[confidence] || null;
}

// ---------------------------------------------------------------------------
// Following dashboard

export async function followingView(page) {
  page.title("Following", state.following.length ? "Latest results of the players you follow" : "");
  const grid = h("div", { class: "cards" });
  const status = h("p", { class: "meta-line" });
  const refreshButton = button("Refresh", {
    icon: "refresh",
    onclick: async () => {
      refreshButton.disabled = true;
      status.textContent = "Refreshing…";
      const errors = await refreshAll({ notify: false });
      refreshButton.disabled = false;
      if (page.isCurrent()) page.reload();
      if (errors.length) console.warn(errors);
    },
  });
  page.actions(refreshButton);

  if (!state.following.length) {
    page.body.append(emptyState(
      "Follow players to see their results here",
      "Open a tournament, choose a player, and click Follow. Their results refresh automatically, and you can get a notification when a new round is played.",
      button("Find a Tournament", { kind: "primary", icon: "trophy", onclick: () => page.navigate("#/tournaments") }),
      button("Find a Player", { icon: "person", onclick: () => page.navigate("#/players") })));
    return;
  }

  const render = () => {
    grid.replaceChildren(...state.following.map((entry) => followCard(page, entry)));
    const newest = Math.max(...state.following.map((entry) => entry.updatedAt || 0));
    const minutes = Number(state.settings.refreshMinutes) || 0;
    status.textContent = [
      newest ? `Updated ${timeAgo(newest)}` : null,
      minutes ? `refreshes every ${minutes} min` : "automatic refresh is off",
      state.settings.notify ? "notifications on" : null,
    ].filter(Boolean).join(" · ");
  };
  page.body.append(grid, status);
  render();

  // Refresh entries that are older than a minute.
  const stale = state.following.some((entry) => !entry.updatedAt || Date.now() - entry.updatedAt > 60_000);
  if (stale) {
    status.textContent = "Refreshing…";
    await refreshAll();
    if (page.isCurrent()) render();
  }
}

function followCard(page, entry) {
  const open = () => page.navigate(`#/tournament/${entry.tournamentId}/player/${entry.startNumber}`);
  const remove = h("button", {
    type: "button", class: "icon-button card-close", title: "Stop following", "aria-label": "Stop following",
    onclick: async (event) => {
      event.stopPropagation();
      await unfollow(entry.tournamentId, entry.startNumber);
      page.reload();
    },
  }, icon("close"));
  const card = h("article", { class: `follow-card clickable ${entry.unseen ? "has-new" : ""}`, tabindex: "0", onclick: open, onkeydown: (event) => { if (event.key === "Enter") open(); } },
    remove,
    entry.unseen ? h("span", { class: "new-badge", text: entry.unseen === 1 ? "New result" : `${entry.unseen} new results` }) : null,
    h("h3", { text: entry.name || `Player ${entry.startNumber}` }),
    h("p", { class: "muted ellipsis", text: entry.tournamentName || tournamentName(entry.tournamentId) }),
    h("div", { class: "follow-stats" },
      h("span", {}, h("strong", { text: formatPoints(entry.points) }), " pts"),
      entry.rank ? h("span", {}, "rank ", h("strong", { text: entry.rank })) : null),
    h("div", { class: "pills" }, (entry.recent || []).map((game) =>
      h("span", { class: "pill", title: `Round ${game.round}${game.opponent_name ? ` vs ${game.opponent_name}` : ""}` }, colorDot(game.color), resultBadge(game)))),
    h("p", { class: "card-foot" }, entry.error ? h("span", { class: "error-text", text: entry.error }) : `Updated ${timeAgo(entry.updatedAt)}`));
  return contextMenu(card, () => [
    { label: "Show Results", symbol: "list.bullet.rectangle", action: open },
    { label: "Open Standings", symbol: "list.number", action: () => page.navigate(`#/tournament/${entry.tournamentId}`) },
    "-",
    { label: "Stop Following", symbol: "eye.slash", action: () => remove.click() },
    "-",
    { label: "Open on Chess-Results", symbol: "safari", action: () => openExternal(chessResultsUrl(entry.tournamentId, entry.startNumber)) },
  ]);
}

// ---------------------------------------------------------------------------
// Settings

export async function settingsView(page) {
  page.title("Settings", "");
  const settings = state.settings;
  const baseUrl = h("input", { class: "field wide", type: "url", value: settings.baseUrl, placeholder: DEFAULT_SETTINGS.baseUrl, spellcheck: "false" });
  const apiKey = h("input", { class: "field wide", type: "password", value: settings.apiKey, placeholder: "Only if the API requires one", autocomplete: "off" });
  const country = h("input", { class: "field country", value: settings.country, maxlength: 3, list: "federations-settings", spellcheck: "false" });
  const refresh = h("select", { class: "field" }, [0, 5, 10, 15, 30, 60].map((minutes) =>
    h("option", { value: minutes, selected: Number(settings.refreshMinutes) === minutes, text: minutes ? `Every ${minutes} minutes` : "Off" })));
  const notify = h("input", { type: "checkbox", checked: settings.notify });
  const connection = h("span", { class: "muted" });
  const saved = h("span", { class: "saved", text: "" });

  const persist = async () => {
    await saveSettings({
      baseUrl: baseUrl.value.trim() || DEFAULT_SETTINGS.baseUrl,
      apiKey: apiKey.value.trim(),
      country: country.value.trim().toUpperCase() || DEFAULT_SETTINGS.country,
      refreshMinutes: Number(refresh.value),
    });
    scheduleRefresh();
    saved.textContent = "Saved";
    setTimeout(() => (saved.textContent = ""), 1500);
  };
  const save = debounce(persist, 400);
  for (const field of [baseUrl, apiKey, country]) field.addEventListener("input", save);
  refresh.addEventListener("change", save);

  notify.addEventListener("change", async () => {
    if (!notify.checked) return saveSettings({ notify: false });
    try {
      await window.japp.notification.show({ title: "Chess Results", body: "Notifications are on. You'll hear about new results of players you follow." });
      await saveSettings({ notify: true });
    } catch (error) {
      notify.checked = false;
      connection.textContent = error.message;
    }
  });

  const test = button("Test Connection", {
    onclick: async () => {
      await persist();
      connection.className = "muted";
      connection.textContent = "Connecting…";
      try {
        const health = await api.health();
        connection.className = "ok-text";
        connection.textContent = `Connected — API status: ${health.status}`;
      } catch (error) {
        connection.className = "error-text";
        connection.textContent = error.message;
      }
    },
  });

  page.actions(saved);
  const row = (label, control, help) => h("div", { class: "setting" }, h("label", { class: "setting-label", text: label }), h("div", { class: "setting-control" }, control, help ? h("p", { class: "help", text: help }) : null));
  const docs = h("a", { class: "subtle-link", href: `${settings.baseUrl.replace(/\/+$/, "")}/docs`, target: "_blank", text: "API documentation" });

  page.body.append(
    h("div", { class: "settings" },
      h("h2", { class: "section-title", text: "Easy Chess Results API" }),
      row("API address", baseUrl, "The server running ChessResultsApi, e.g. your Raspberry Pi behind ngrok or Tailscale."),
      row("API key", apiKey, "Sent as “Authorization: Bearer …” when the server has API_KEYS configured."),
      row("", h("div", { class: "inline" }, test, connection)),
      h("h2", { class: "section-title", text: "Preferences" }),
      row("Default federation", country, "Three-letter code used for new tournament searches; “-” means all countries."),
      row("Refresh followed players", refresh),
      row("Notifications", h("label", { class: "checkbox" }, notify, h("span", { text: "Notify me when a followed player has a new result" }))),
      h("datalist", { id: "federations-settings" }, [h("option", { value: "-" }), ...FEDERATIONS.map((code) => h("option", { value: code }))]),
      h("p", { class: "about" }, docs, ` · Chess Results ${window.japp?.app.version ?? ""} on JApp Runtime ${window.japp?.runtimeVersion ?? "(browser)"}`)));
}
