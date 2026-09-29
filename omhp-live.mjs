#!/usr/bin/env node
// Live boss feed for omhp-bot.sh: follows the game's WebSocket stream
// (/api/live) and keeps a small JSON file with the latest boss state, so the
// bash bot can watch HP in near real time without polling the API.
//
// Usage: node omhp-live.mjs OUT_FILE
// Env:   OMHP_API        API origin (default https://onemillionhp.com)
//        OMHP_TOKEN      optional; identifies us so admin gifts are announced
//        OMHP_PLAYER_ID  our player id, excluded from the others' damage rate
//        OMHP_SKEW       server_time - local time, seconds (for the lag figure)
//        OMHP_PARENT_PID exit when this process is gone
//
// OUT_FILE (replaced atomically on every message):
//   { boss, connected, written, recv, rate, lag, gifts }
//   connected = the socket is open (a quiet boss sends nothing, so an old
//               `recv` alone doesn't mean the feed is dead)
//   written   = local unix time of this write (the helper rewrites every 1s)
//   recv      = local unix time the last message arrived
//   rate  = HP/s dealt by other players over the last RATE_WINDOW seconds
//   lag   = how far the stream trails the server (seconds, smoothed)
//   gifts = count of gift/shards messages (a change means: refresh /api/me)
// Requires Node 22+ (built-in WebSocket).

import { renameSync, writeFileSync } from "node:fs";

const out = process.argv[2];
if (!out) {
  console.error("usage: node omhp-live.mjs OUT_FILE");
  process.exit(2);
}
if (typeof WebSocket !== "function") {
  console.error("omhp-live: this Node has no built-in WebSocket (need Node 22+)");
  process.exit(3);
}

const api = (process.env.OMHP_API || "https://onemillionhp.com").replace(/\/$/, "");
const url = api.replace(/^http/, "ws") + "/api/live";
const token = process.env.OMHP_TOKEN || "";
const me = process.env.OMHP_PLAYER_ID || "";
const skew = Number(process.env.OMHP_SKEW || 0);
const parent = Number(process.env.OMHP_PARENT_PID || 0);

const RATE_WINDOW = 5; // seconds of others' hits used for the damage rate

let boss = null;
let lag = null;
let gifts = 0;
let connected = false;
let recv = 0;
let since = 0; // server time we started counting hits (connect or new boss) // when the last real message arrived (the stream is stale if this is old)
/** @type {{t: number, damage: number}[]} */
let hits = [];

const serverNow = () => Date.now() / 1000 + skew;

function write() {
  // Hits from the last `lag` seconds haven't reached us yet: end the window there.
  const now = serverNow() - (lag ?? 0);
  hits = hits.filter((h) => h.t >= now - RATE_WINDOW);
  // Divide by the time actually observed, so the rate is right just after connecting.
  const span = Math.max(1, Math.min(RATE_WINDOW, now - since));
  const rate = hits.reduce((s, h) => s + h.damage, 0) / span;
  const tmp = `${out}.tmp`;
  writeFileSync(tmp, JSON.stringify({ boss, connected, written: Date.now() / 1000, recv, rate: Math.round(rate * 10) / 10, lag, gifts }));
  renameSync(tmp, out);
}

function onMessage(msg) {
  if (msg.type === "snapshot" || msg.type === "update" || msg.type === "refresh") {
    if (msg.boss) {
      // A new boss resets the rate window.
      if (boss && msg.boss.seq !== boss.seq) {
        hits = [];
        since = serverNow();
      }
      boss = msg.boss;
    }
    for (const e of msg.events ?? []) {
      if (typeof e.t !== "number") continue;
      const l = serverNow() - e.t;
      if (l >= 0 && l < 30) lag = lag === null ? l : 0.8 * lag + 0.2 * l;
      if (e.damage > 0 && e.player_id !== me) hits.push({ t: e.t, damage: e.damage });
    }
  } else if (msg.type === "gift" || msg.type === "shards") {
    gifts++;
  } else {
    return;
  }
  recv = Date.now() / 1000;
  write();
}

let backoff = 1000;
function open() {
  const ws = new WebSocket(url);
  ws.onopen = () => {
    backoff = 1000;
    connected = true;
    hits = [];
    since = serverNow();
    if (token) ws.send(JSON.stringify({ type: "auth", token }));
  };
  ws.onmessage = (ev) => {
    try {
      onMessage(JSON.parse(ev.data));
    } catch {
      /* ignore malformed frames */
    }
  };
  ws.onclose = () => {
    connected = false;
    if (boss) write();
    setTimeout(open, backoff);
    backoff = Math.min(30000, backoff * 2);
  };
  // A failed socket fires "close" after "error"; reconnecting happens there.
  // (Calling ws.close() in here recurses in Node's WebSocket.)
  ws.onerror = () => {};
}

// Refresh the rate even when no one attacks (it should decay to 0), and
// stop once the bot that started us has exited.
setInterval(() => {
  if (parent) {
    try {
      process.kill(parent, 0);
    } catch {
      process.exit(0);
    }
  }
  if (boss) write();
}, 1000);

open();
