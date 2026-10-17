// Followed players: periodic refresh, "new result" detection and notifications.

import { api } from "./api.js";
import { rememberTournaments, state, saveFollowing, tournamentName } from "./store.js";
import { describeGame, isDecided } from "./ui.js";

const RECENT_GAMES = 8;
let timer = null;
let running = null;

const hasResult = (game) => isDecided(game) || Boolean(game.source_result_text && game.source_result_text.trim());

/** Builds the stored summary of a player's results. */
export function summarize(results) {
  const games = results.games || [];
  return {
    name: results.player?.name,
    points: results.player?.points ?? null,
    rank: results.player?.rank ?? null,
    played: games.filter(hasResult).length,
    recent: games.slice(-RECENT_GAMES).map((game) => ({
      round: game.round,
      color: game.color,
      result_kind: game.result_kind,
      result: game.result,
      source_result_text: game.source_result_text,
      opponent_name: game.opponent_name,
    })),
  };
}

/** Records that the user has looked at a followed player's latest results. */
export async function markSeen(tournamentId, startNumber, results) {
  const entry = state.following.find((item) => item.tournamentId === String(tournamentId) && item.startNumber === String(startNumber));
  if (!entry) return;
  Object.assign(entry, summarize(results), { unseen: 0, updatedAt: Date.now() });
  await saveFollowing();
}

/**
 * Refreshes every followed player. New results are counted in `unseen` and,
 * if enabled, announced with a notification. Runs one refresh at a time.
 */
export function refreshAll({ notify = true } = {}) {
  if (running) return running;
  running = (async () => {
    const errors = [];
    for (const entry of state.following) {
      try {
        const results = (await api.results(entry.tournamentId, entry.startNumber, { ttl: 0 })).data;
        const summary = summarize(results);
        const hadData = entry.played !== undefined && entry.played !== null;
        const improved = hadData && (summary.played > entry.played || (summary.points ?? 0) !== (entry.points ?? 0));
        if (improved) {
          entry.unseen = (entry.unseen || 0) + Math.max(1, summary.played - entry.played);
          if (notify && state.settings.notify) announce(entry, results);
        }
        Object.assign(entry, summary, { updatedAt: Date.now(), error: null });
        if (!entry.tournamentName || entry.tournamentName.startsWith("Tournament ")) {
          entry.tournamentName = tournamentName(entry.tournamentId);
          if (entry.tournamentName.startsWith("Tournament ") && results.player?.player_key) {
            const profile = (await api.playerProfile(results.player.player_key, { ttl: 10 * 60_000 }).catch(() => null))?.data || {};
            const appearance = (profile.appearances || []).find((item) => String(item.tournament_id) === String(entry.tournamentId));
            if (appearance?.tournament_name) {
              entry.tournamentName = appearance.tournament_name;
              rememberTournaments([{ id: entry.tournamentId, name: appearance.tournament_name, ends_on: appearance.ends_on }]);
            }
          }
        }
      } catch (error) {
        entry.error = error.message;
        errors.push(error);
      }
    }
    await saveFollowing();
    return errors;
  })().finally(() => {
    running = null;
  });
  return running;
}

function announce(entry, results) {
  const last = [...(results.games || [])].reverse().find(hasResult);
  const body = [last ? describeGame(last) : "New results", `Score: ${results.player?.points ?? "?"}`].join(" · ");
  window.japp?.notification
    ?.show({ title: results.player?.name || entry.name || "Followed player", subtitle: entry.tournamentName, body })
    .catch((error) => console.warn("Notification failed:", error.message));
}

/** (Re)starts the auto-refresh timer from the current settings. */
export function scheduleRefresh() {
  clearInterval(timer);
  const minutes = Number(state.settings.refreshMinutes) || 0;
  if (minutes > 0) timer = setInterval(() => refreshAll().catch(console.error), minutes * 60_000);
}
