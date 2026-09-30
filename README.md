# one-million-hp-bot

A small bash bot that plays [ONE MILLION HP](https://onemillionhp.com) for you.

## What it does

Every API response includes your updated player state (`me`), and the bot picks its next move from it:

1. **Ultimate available** → use it, always. It does damage right away, and your charm's refunds recharge it.
2. **Loot box in the bag** → open it. Wooden crates and iron chests are the exception: they're banked unopened until the kill attempt itself (see below).
3. **Enough shards for an Occult Ossuary** (500 by default) → buy one. The next pass opens it through step 2.
4. **Attacks left** → attack. If the boss is at 5% HP or less, hoard instead (see [Last-hit hoarding](#last-hit-hoarding)).
5. **Nothing to do** → sleep until the next attack recharges (`next_attack_at`), then refresh.
6. **Boss not alive** → check again every 30s until the next boss spawns.

Attacks recharge one every 5s, up to 20 stored.

### Regenerated ultimates and attacks

Normally you get one ultimate per boss, but the admin can grant more, and so can some attack effects (the `refund` proc, "ULT RECHARGED!"). Attacks can also go above the 20 cap through bonus attacks from the admin or from procs (for example the `saved` proc, "FREE ATTACK!").

The bot doesn't track any of these counts itself. It reads `ultimate_available` and `attacks_left` from the latest server state on every loop, so a regenerated ultimate or bonus attack gets used on the next pass. Grants that arrive while the bot is sleeping are seen at the next refresh, which is at most one recharge interval later.

### Last-hit hoarding

Other players save their ultimates (900–1900 damage each) and use them at the end. The last real bosses went from 1500–3000 HP to dead in a single ultimate. A burst of 20 normal hits (~430 damage) is too small to compete. Crit charges from loot boxes ("next 3 attacks will crit", ~200–700 damage each) are what make the killing blow reachable. The strategy has three parts:

1. **Bank boxes for crit charges.** Wooden crates and iron chests (`OMHP_BANK_BOXES`) stay unopened, up to `OMHP_BANK_MAX` (50). Beyond that, the extras are opened as usual. Other boxes (ossuaries, cursed caskets) still open right away. A full bank of 50 (about 36 crates and 14 chests) is worth about 12 crit charges and 30 attacks on average.
2. **Hoard from 5% boss HP** (`OMHP_HOARD_PCT`). Normal attacks are only spent at the attack cap, so the bank is full when the endgame rush starts. That costs nothing, because recharge keeps flowing. If a charge does exist (from a cursed casket, say), the bot stops spending even at the cap, because the game would spend the charge on the next attack. The ultimate is still used as soon as it's ready. While hoarding, no box is opened at all, including cursed caskets bought during the hoard: a crit charge would stop the bot from spending at the attack cap and waste recharge. Every box in the bag goes into the burst.
3. **Weave the bank into the burst.** The game spends crit charges on your very next attacks, so the banked boxes stay shut until the kill attempt itself. The bot predicts the boss's HP when a burst would land. Once that's within reach of a burst with the charges the bank will likely produce, it fires one burst that alternates box opens and attacks (open, attack, open, attack…), all in parallel. Box opens and attacks are separate endpoints with their own rate limits, so weaving adds no time, and each charge is created just before the attacks that use it. The burst sends the attacks you hold plus the ones the bank is expected to add; any extra attack requests are rejected. If someone else kills the boss first, nothing is lost: the boxes stay banked for the next boss.

While hoarding, the bot works out when to fire from these numbers:

- **Boss HP**, from the live feed (below), or from `/api/state` if the feed isn't available.
- **Other players' steady damage rate** (HP per second), not counting our own hits or big hits (crits and ultimates over 200 damage).
- **What one burst can deal**, estimated as one sum: every attack in the burst (the ones held plus the ones the bank is expected to add), with crit charges (existing ones plus the bank's expected yield from the game's box odds) on some of them. The mean and spread of your crits and normal hits come from your most recent 1,000 hits and 150 crits in the session logs (only while the boss was above 10% HP), refreshed once a minute. Below 10% HP every hit also gets your gear's executioner bonus (`me.mods.executioner`, +25% for THE UNWRITTEN END), which the estimate applies on top. The reach is the burst's mean minus `OMHP_MARGIN_SD` (1.5) standard deviations, so about 93% of bursts deal at least that much. For a 50-box bank and 20 held attacks, that's ~4,300 HP.
- **How long until a burst lands:** how far behind the live feed is (`lag`), plus how long our requests take to reach the server (`OMHP_FIRE_LEAD`, 0.3s).

| Situation | Action |
| --- | --- |
| The predicted HP is within what one woven burst can deal | **Fire:** open every banked box and send every attack, interleaved and in parallel. Attacks that arrive after the kill are rejected. |
| It will be within reach before the next check | **Time the shot:** sleep exactly until then, then fire. |
| We're at the attack cap with no crit charges | **Spend one attack** so recharge isn't wasted. |
| Otherwise | Keep watching. |

After each boss dies, the bot logs who got the killing blow, and the session summary counts your last hits. Every attack record also stores the boss's HP at that moment, for tuning.

#### Live feed (WebSocket)

The game streams every attack over a WebSocket at `/api/live`. With Node 22+ installed, the bot starts `omhp-live.mjs` next to itself. The helper follows that stream and writes the latest boss state to a small file, which the bot reads every 0.2s while hoarding. That gives:

- **HP every 0.2s,** without an HTTP request per check.
- **An accurate damage rate for other players,** because each event names the attacker, so our own hits can be left out.
- **The feed's lag,** from each event's server timestamp. The live site ran 0.15–0.3s behind.

If Node isn't installed, is older than 22, or the feed disconnects, hoarding falls back to polling `/api/state` every `OMHP_HOARD_POLL` seconds (1s). Set `OMHP_LIVE=0` to always poll.

#### How well it works

**Replaying the real endgames.** I rebuilt the last ~600 hits of bosses 13–16 from `/api/feed` and replayed them through the firing rule. The replay models a 0.25s feed lag, 0.25s for our requests to arrive, and your real hit, crit and ultimate damage. The old rule (hoard from 1%, no crit charges) reproduced what actually happened: boss 13 won, 14–16 lost. With 20 banked attacks, win rate by number of crit charges:

| Crit charges | Boss 13 | Boss 14 | Boss 15 | Boss 16 |
| --- | --- | --- | --- | --- |
| 0 | 100% | too late | too late | too late |
| 3 | 100% | too late | too late | too late |
| 6 | 100% | too late | too late | 97% |
| 10 | 100% | 100% | 100% | 100% |

**Simulator.** In a simulated endgame, other players deal a steady 150 HP/s plus an ultimate-sized hit (800–1900) every ~1.2s on average. Last hits out of 6:

| Crit charges | Before the steady-rate fix | After |
| --- | --- | --- |
| 0 | 1/6 | 2/6 |
| 6 | 0/6 | 4/6 |
| 10 | 3/6 | 6/6 |

**Boss 18 (real).** HP sat between 2,993 and 2,482 for ~3s, then two other players' ultimates finished it. The bot, holding ~6 charges and ~40 attacks, never fired. It counted every crit at the 25th percentile and the bank at mean − 1.5 sd, and it left out the attacks the bank adds, which put its reach at ~1,700–2,100. Replaying the real endgames of bosses 13–16 and 18 with the whole-burst estimate (55-box bank, 20 attacks) gives these win rates:

| `OMHP_MARGIN_SD` | Reach | 13 | 14 | 15 | 16 | 18 | Avg |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 1.5 | ~3,400 | 97% | 100% | 99% | 96% | 98% | 98% |
| 1.0 | ~4,100 | 85% | 99% | 82% | 87% | 84% | 88% |
| 0.5 | ~4,700 | 87% | 80% | 71% | 75% | 84% | 80% |
| 0 | ~5,400 | 49% | 54% | 51% | 73% | 52% | 56% |

At 1.5 none of the five were too late. Lower values fire earlier, but more bursts fall short.

**Boss 21 (real) and the 30-box bank.** Boss 21 sat at 4,000–6,000 HP for ~20s, then six big hits in the last second took it from 4,381 to dead. With the bank cut to 30 boxes, a 1.5-sd margin put the reach at only ~2,200, and the burst went out as the boss died. Replaying bosses 13–16, 18 and 21 with the current damage (crits ~550 with executioner):

| Bank | `OMHP_MARGIN_SD` | Reach | Avg win | Too late |
| --- | --- | --- | --- | --- |
| 30 boxes | 1.5 | ~2,200 | 49% | 3 of 6 |
| 30 boxes | 1.0 | ~3,000 | 76% | 1 of 6 |
| 30 boxes | 0.5 | ~3,800 | 81% | 0 |
| 30 boxes | 0 | ~4,600 | 59% | 0 |
| **50 boxes** | 2.0 | ~3,200 | 100% | 0 (fires at the edge of the final rush) |
| **50 boxes** | **1.5** (default) | ~4,300 | **97%** | 0 |
| **50 boxes** | 1.0 | ~5,300 | 86% | 0 |
| 60 boxes | 1.5 | ~5,300 | 96% | 0 |
| 60 boxes | 0.5 | ~7,600 | 74% | 0 |

The bank size matters more than the margin, so the defaults are now a 50-box bank with a 1.5-sd margin (97%). With a smaller bank, lower the margin to match (30 boxes: `OMHP_MARGIN_SD=0.5`).

**Bank woven into the burst** (same simulated endgame, 40 crates and 15 chests banked, 0 charges to start): **6/6** last hits. Each burst took ~0.63s. The 55 box opens made 9–15 crit charges, and the boss died after 4–25 of our hits, 1–4 of them crits. Opening the whole bank first and then firing managed 4/6: the 0.7–0.8s it took to open let other players' hits land first. Charges left over when the boss dies carry into the next boss and go on your first normal attacks there.

"Before" projected HP with the average rate, which big hits inflate, so the bot fired while the boss was still out of reach. Big hits are rare jumps, and one usually doesn't land in the ~0.5s a burst is in flight. So the bot now projects with the **steady** rate: the live feed leaves out hits over 200 damage (`OMHP_BIG_HIT`), and polling takes the median of the last 5 samples.

On the real server the results also depend on network latency, on how concurrent attacks from one player are processed, on whether rejected attacks really cost nothing, and on other players changing their own timing.

### Buying Occult Ossuaries

When your shard balance reaches the ossuary's price (500), the bot buys one and opens it right away. It keeps buying as long as you can afford another. While hoarding, bought boxes stay shut and go into the kill burst.

The ossuary's loot table was updated to drop godly items more often: epic 64.4%, legendary 28%, mythic 5.6%, **godly 1.9%**. Per shard, that's about 5× the cursed casket's godly odds (the casket is 0.1% godly at 100 shards). The casket is still better per shard for mythics (2.3% at 100) and gives crit charges; set `OMHP_BUY_BOX=cursed_casket` to go back to it.

- The price comes from `me.shop.boxes`, which includes any price changes the admin makes. If that field is missing, the bot uses the shop list at the time of writing (crate 10, chest 30, casket 100, ossuary 500).
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
| `OMHP_BUY_BOX`    | `occult_ossuary`            | Box to buy with shards; empty disables buying |
| `OMHP_LOG_DIR`    | `./logs` (next to the script) | Where session logs are written            |
| `OMHP_HOARD_PCT`  | `5`                         | Start hoarding at this % of boss HP; `0` disables hoarding |
| `OMHP_BANK_BOXES` | `wooden_crate,iron_chest`   | Box types kept unopened until hoarding; empty disables banking |
| `OMHP_BANK_MAX`   | `50`                        | Open banked boxes beyond this many |
| `OMHP_BIG_HIT`    | `200`                       | Other players' hits above this are left out of the steady damage rate |
| `OMHP_FIRE_LEAD`  | `0.3`                       | Seconds for our attacks to reach the server |
| `OMHP_HIT_EST`    | `20`                        | Per-hit damage guess before the logs have any hits |
| `OMHP_MARGIN_SD`  | `1.5`                       | Fire when the predicted HP is within the burst's mean minus this many standard deviations; lower fires earlier |
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
