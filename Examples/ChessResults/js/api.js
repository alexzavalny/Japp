// Client for the Easy Chess Results API (see its OpenAPI contract at <base>/docs).
//
// Inside JApp Runtime requests go through japp.http.fetch, which is not subject
// to CORS, so the API does not need to allow this app's origin. In a normal
// browser it falls back to fetch().

import { state } from "./store.js";

export class ApiError extends Error {
  constructor(message, { status = 0, network = false } = {}) {
    super(message);
    this.name = "ApiError";
    this.status = status;
    this.network = network;
  }
}

const cache = new Map(); // url → { time, body }

function baseUrl() {
  return state.settings.baseUrl.trim().replace(/\/+$/, "");
}

/**
 * GETs `path` with query `params`. Responses are cached in memory for `ttl`
 * milliseconds; `refresh: true` asks the API to refetch from Chess-Results.
 */
export async function request(path, params = {}, { refresh = false, ttl = 60_000 } = {}) {
  const base = baseUrl();
  if (!/^https?:\/\//.test(base)) throw new ApiError("Set the API address in Settings.");

  const url = new URL(base + path);
  for (const [name, value] of Object.entries(params)) {
    if (value !== undefined && value !== null && value !== "") url.searchParams.set(name, value);
  }
  const cacheKey = url.toString();
  if (!refresh) {
    const hit = cache.get(cacheKey);
    if (hit && Date.now() - hit.time < ttl) return hit.body;
  } else {
    url.searchParams.set("refresh", "true");
  }

  const headers = {
    Accept: "application/json",
    // ngrok's free tier shows an HTML warning page to browser-like clients without this.
    "ngrok-skip-browser-warning": "true",
  };
  if (state.settings.apiKey) headers.Authorization = `Bearer ${state.settings.apiKey}`;

  let response;
  try {
    response = window.japp?.http
      ? await window.japp.http.fetch(url.toString(), { headers, timeout: 45 })
      : await fetch(url.toString(), { headers });
  } catch (error) {
    throw new ApiError(`Can't reach the API at ${base}. ${error.message || ""}`.trim(), { network: true });
  }

  const text = await response.text();
  let body;
  try {
    body = JSON.parse(text);
  } catch {
    throw new ApiError(
      response.ok
        ? "The API answered with something that isn't JSON. Check the API address in Settings."
        : `The API answered HTTP ${response.status}.`,
      { status: response.status }
    );
  }
  if (!response.ok) {
    const message = body?.error?.message || `HTTP ${response.status} ${response.statusText || ""}`.trim();
    throw new ApiError(response.status === 401 ? `${message} — set the API key in Settings.` : message, { status: response.status });
  }
  cache.set(cacheKey, { time: Date.now(), body });
  return body;
}

const id = (value) => encodeURIComponent(String(value));

export const api = {
  health: () => request("/health/ready", {}, { ttl: 0 }),
  searchTournaments: (params, options) => request("/api/v1/tournaments", params, { ttl: 5 * 60_000, ...options }),
  tournament: (tournamentId, options) => request(`/api/v1/tournaments/${id(tournamentId)}`, {}, options),
  standings: (tournamentId, params, options) => request(`/api/v1/tournaments/${id(tournamentId)}/standings`, params, options),
  player: (tournamentId, startNumber, options) =>
    request(`/api/v1/tournaments/${id(tournamentId)}/players/${id(startNumber)}`, {}, options),
  results: (tournamentId, startNumber, options) =>
    request(`/api/v1/tournaments/${id(tournamentId)}/players/${id(startNumber)}/results`, {}, options),
  searchPlayers: (query, options) => request("/api/v1/players", { q: query }, options),
  playerProfile: (playerKey, options) => request(`/api/v1/players/${id(playerKey)}`, {}, options),
};

export const chessResultsUrl = (tournamentId, startNumber) =>
  startNumber
    ? `https://s2.chess-results.com/tnr${tournamentId}.aspx?lan=1&art=9&snr=${startNumber}`
    : `https://s2.chess-results.com/tnr${tournamentId}.aspx?lan=1`;
