# one-million-hp-bot

A small bash bot that plays [ONE MILLION HP](https://onemillionhp.com) for you.

## What it does

Every API response includes your updated player state (`me`), and the bot picks its next move from it:

1. **Ultimate available** → use it (unless hoarding, see below).
2. **Loot box in the bag** → open it.
3. **Enough shards for a Cursed Casket** (100 by default) → buy one. The next pass opens it through step 2.
4. **Attacks left** → attack. If the boss is at 1% HP or less, hoard instead (see [Last-hit hoarding](#last-hit-hoarding)).
5. **Nothing to do** → sleep until the next attack recharges (`next_attack_at`), then refresh.
6. **Boss not alive** → check again every 30s until the next boss spawns.

Attacks recharge one every 5s, up to 20 stored.

### Regenerated ultimates and attacks

Normally you get one ultimate per boss, but the admin can grant more, and so can some attack effects (the `refund` proc, "ULT RECHARGED!"). Attacks can also go above the 20 cap through bonus attacks from the admin or from procs (for example the `saved` proc, "FREE ATTACK!").

The bot doesn't track any of these counts itself. It reads `ultimate_available` and `attacks_left` from the latest server state on every loop, so a regenerated ultimate or bonus attack gets used on the next pass. Grants that arrive while the bot is sleeping are seen at the next refresh, which is at most one recharge interval later.

### Last-hit hoarding

When the boss drops to 1% of its HP or less (`OMHP_HOARD_PCT`), the bot stops spending attacks and the ultimate. It saves them for one burst aimed at the killing blow. It keeps opening and buying boxes while it waits, because boxes can give more attacks.

While hoarding, the bot works out when to fire from four numbers:

- **Boss HP**, from the live feed (below), or from `/api/state` if the feed isn't available.
- **Other players' damage rate** (HP per second), not counting our own hits.
- **Our damage per hit**, using a cautious estimate: the 25th percentile of this session's non-crit hits. The ultimate counts as the smallest ultimate seen this session. Before any ultimate this session, it counts as 0.
- **How long until a burst lands:** how far behind the live feed is (`lag`), plus how long our requests take to reach the server (`OMHP_FIRE_LEAD`, 0.3s).

From these it predicts the boss's HP at the moment a burst would arrive, and then:

| Situation | Action |
| --- | --- |
| That HP is within what we hold | **Fire** enough attacks to kill the HP we currently see, plus `OMHP_BURST_EXTRA` (2), and the ultimate, all in parallel. Attacks that arrive after the kill are rejected. |
| It will be within reach before the next check | **Time the shot:** sleep exactly until then, then fire everything. |
| We're at the attack cap | **Spend one attack** so recharge isn't wasted. This also pushes the boss toward kill range if nobody else is attacking. |
| Otherwise | Keep watching. |

After each boss dies, the bot logs who got the killing blow. The session summary counts your last hits.

#### Live feed (WebSocket)

The game streams every attack over a WebSocket at `/api/live`. With Node 22+ installed, the bot starts `omhp-live.mjs` next to itself. The helper follows that stream and writes the latest boss state to a small file, which the bot reads every 0.2s while hoarding. That gives:

- **HP every 0.2s,** without an HTTP request per check.
- **An accurate damage rate for other players,** because each event names the attacker, so our own hits can be left out.
- **The feed's lag,** from each event's server timestamp. The live site ran 0.15–0.3s behind.

If Node isn't installed, is older than 22, or the feed disconnects, hoarding falls back to polling `/api/state` every `OMHP_HOARD_POLL` seconds (1s). Set `OMHP_LIVE=0` to always poll.

#### How well it works

I tested this against a local simulator of the game, not the real server. The simulated server adds 50–200ms of request latency and a 0.3s feed lag. The simulator's ultimate was turned off so the attacks alone had to land the kill. Last hits out of 6 bosses:

| Other players' damage | Live feed | Polling |
| --- | --- | --- |
| 300 HP/s | 6/6 | 6/6 |
| 1000 HP/s | 6/6 | 6/6 |
| 3000 HP/s | 3/6 | 3/6 |

When I sampled the real boss, other players dealt about 30–560 HP/s. At 3000 HP/s, by the time a burst arrives, someone else often has already killed the boss.

This test favors polling, because the simulated `/api/state` has no lag. The feed's advantages are its damage rate and checking HP 5 times a second without calling the API.

On the real server the results also depend on network latency to the server, on how concurrent attacks from one player are processed, and on whether rejected attacks really cost nothing. Those are assumptions until you've watched a real kill.

### Buying Cursed Caskets

When your shard balance reaches the casket's price, the bot buys one and opens it right away. It keeps buying as long as you can afford another, so 250 shards gets you two caskets, with 50 shards left over.

- The price comes from `me.shop.boxes`, which includes any price changes the admin makes. If that field is missing, the bot assumes 100.
- To buy a different box, set `OMHP_BUY_BOX` to its ID (`wooden_crate`, `iron_chest`, `cursed_casket`, `occult_ossuary`). To turn buying off, set it to an empty string (`OMHP_BUY_BOX=`).
- If the server refuses a purchase, the bot doesn't retry until your shard count changes, so it can't get stuck retrying the same failed purchase.

### Session summary

Every attack, box opening and purchase is appended to `logs/session-YYYYMMDD-HHMMSS.jsonl`. When the bot stops (Ctrl-C, `kill`, or `systemctl stop`), it prints a summary built from that file:

```
=============== SESSION SUMMARY ===============
Duration        1h 2m 5s
Attacks         6   (normal 3, crit 2, ultimate 1)
Total damage    11,253
Avg damage      normal 44   crit 1350   ultimate 8421
Last hits       1 of 1 boss kill(s) seen
Loot boxes      10 opened  (1 bought for 100 shards)
  CURSED CASKET x4
      LEGENDARY x1: GOLDEN SWORD
      EPIC x2: VOID HAMMER x2
      crit charges +3
  IRON CHEST x2
      ultimate recharge x1
  WOODEN CRATE x3
      COMMON x1: RUSTED SWORD (auto-sold)
      attacks +3
===============================================
```

- **Attack types:** "normal" counts only non-crit normal attacks, and "crit" counts normal attacks that crit. Ultimates are counted separately.
- **Box order:** box types are listed from best to worst, and within each box, items are listed from rarest to most common.
- **Old sessions:** to re-print the summary of an earlier session, run:

```bash
./omhp-bot.sh --summary logs/session-20260929-014027.jsonl
```

### What it does not do

- It doesn't equip items. Drops go into your bag, and you manage equipment in the web UI.
- It doesn't sell items for shards. Shards only grow from sales you make yourself, including the game's own auto-sell setting.

## Requirements

- `bash`, `curl`, `uuidgen` (all included with macOS)
- `jq`: `brew install jq`
- Optional: Node 22+ for the live feed (`brew install node`). Without it, hoarding polls the API instead.

## Usage

1. Open https://onemillionhp.com in your browser. Your player must already have a name; the server refuses attacks until one is set.
2. Open devtools → Console and copy your token:
   ```js
   localStorage.getItem("omhp.token")
   ```
3. Run the bot:
   ```bash
   OMHP_TOKEN=paste_token_here ./omhp-bot.sh
   ```
4. Press Ctrl-C to stop.

### Options (environment variables)

| Variable          | Default                     | Meaning                                    |
| ----------------- | --------------------------- | ------------------------------------------ |
| `OMHP_TOKEN`      | required                    | Your bearer token                          |
| `OMHP_API`        | `https://onemillionhp.com`  | API origin                                 |
| `OMHP_PAUSE`      | `0.4`                       | Seconds between consecutive actions        |
| `OMHP_DEAD_POLL`  | `30`                        | Seconds between checks while no boss is alive |
| `OMHP_BUY_BOX`    | `cursed_casket`             | Box to buy with shards; empty disables buying |
| `OMHP_LOG_DIR`    | `./logs` (next to the script) | Where session logs are written            |
| `OMHP_HOARD_PCT`  | `1`                         | Start hoarding at this % of boss HP; `0` disables hoarding |
| `OMHP_BURST_EXTRA`| `2`                         | Extra attacks on top of the estimated kill count |
| `OMHP_FIRE_LEAD`  | `0.3`                       | Seconds for our attacks to reach the server |
| `OMHP_HIT_EST`    | `1`                         | Per-hit damage guess before this session has any hits |
| `OMHP_LIVE`       | `1`                         | Use the WebSocket feed when Node 22+ is available |
| `OMHP_LIVE_POLL`  | `0.2`                       | Seconds between live-feed reads while hoarding |
| `OMHP_HOARD_POLL` | `1`                         | Seconds between `/api/state` polls while hoarding without the feed |

## Example output (illustrative)

```
01:12:03  Playing as ziploc  (clock skew 0.214s)
01:12:03    attacks 20/20  boss dmg 0  boxes 1  shards 104  ult READY
01:12:04  ULTIMATE: 8421 dmg
01:12:04    attacks 20/20  boss dmg 8421  boxes 1  shards 104  ult spent
01:12:04  OPENED wooden_crate -> {...}
01:12:05  BOUGHT cursed_casket for 100 shards  (4 left)
01:12:05  OPENED cursed_casket -> {...}
01:12:05  NORMAL: 37 dmg
01:12:05    attacks 19/20  boss dmg 8458  boxes 0  shards 4  ult spent
01:12:06  NORMAL: 112 dmg CRIT  +box wooden_crate  [refund]
```

## API reference

These are the endpoints the game's own web client uses, found by reading `js/api.js` on the site:

| Call                       | Body                                   |
| -------------------------- | -------------------------------------- |
| `GET  /api/me`             | (none)                                 |
| `GET  /api/state`          | (none; public; includes `server_time` and `boss`) |
| `WS   /api/live`           | Push stream: `snapshot`, then an `update` per attack with `boss` and `events` (`t`, `player_id`, `damage`); also `gift` and `shards`. Send `{"type":"auth","token":...}` to be told about gifts. |
| `POST /api/attack`         | `{ "kind": "normal" \| "ultimate", "request_id": uuid }` |
| `POST /api/boxes/open`     | `{ "box_id": string, "request_id": uuid }` |
| `POST /api/shop/buy`       | `{ "box_id": string }`                 |
| `POST /api/me/equip`       | `{ "item_id": string \| null, "slot"?: string }` |

All authenticated calls send `Authorization: Bearer <token>`. The `request_id` makes a retry safe: if you resend the same ID, the server returns the original result instead of acting twice.

## Error handling

| Error                          | Behavior                    |
| ------------------------------ | --------------------------- |
| `UNAUTHENTICATED` / 401        | Exit (bad token)            |
| `NEED_NAME`                    | Exit (set a name in the web UI) |
| Network error, 429, 5xx        | Wait 5s, refresh, continue  |
| Anything else (e.g. `NO_ATTACKS`, `ULTIMATE_USED`) | Refresh state, continue |

## Notes

- Your token is your whole account. Don't commit it or share it.
- Automated play may be against the game's rules. Use it at your own discretion.
