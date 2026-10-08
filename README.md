# one-million-hp-bot

A small bash bot that plays [ONE MILLION HP](https://onemillionhp.com) for you.

## What it does

Every API response includes your updated player state (`me`), and the bot picks its next move from it:

1. **Ultimate ready** → use it. While it recharges, normal attacks are held and then all spent right after the next ultimate (see [The ultimate cycle](#the-ultimate-cycle)).
2. **Scroll owned** → ignored by default. With `OMHP_SCROLLS=1`, the bot uses it right away; a scroll the server refuses (boss heal only works at 89% boss HP or lower) is set aside for 2 minutes instead of being retried every pass.
3. **Enough shards for the most expensive loot box** (currently the Void Reliquary, 500) → buy one. The bot never opens boxes: bought and dropped boxes stay in your bag for you to open in the web UI.
4. **Attacks left** → attack, at most one normal attack every 0.8s (`OMHP_ATTACK_GAP`). The gap applies only to normal attacks; the ultimate, scrolls and purchases don't wait on it.
5. **Nothing to do** → sleep until the next attack recharges (`next_attack_at`), then refresh.
6. **Boss not alive** → check again every 30s until the next boss spawns.

Attacks recharge one every 5s, up to 20 stored.

### Captchas

The game's bot scan can push an "ARE YOU HUMAN?" check to a player (`me.captcha`). Until it's answered, the server refuses attacks and scrolls, and 10 wrong answers in total ban the account. **The bot never answers captchas.** When one is pending it:

- stops sending actions (attacks, the ultimate, scrolls, purchases) and only refreshes your state every 30s (`OMHP_CAPTCHA_POLL`);
- logs `!!! CAPTCHA: ... Answer it in the web UI.`, records it in the session log, and on macOS shows a notification (`OMHP_NOTIFY=0` turns that off; there's no notification where `osascript` doesn't exist, such as a Linux VPS);
- resumes as soon as an attack goes through again and logs how long it was paused. The session summary counts captchas and the total pause.

If the server only signals the captcha through an error code on a refused attack (no `me.captcha` field), the bot still pauses, probing with one attack per check instead of retrying every second.

### The ultimate cycle

The ultimate recharges on a 60-second timer (`me.ultimate_ready_at`, `me.ult_recharge`), and each normal attack has a chance to refund a spent one (1.5% with LAST SAVE POINT). Your logs show the timer **restarts when the ultimate is used**: after a refunded ultimate, the next timed one came 55–65s later. So when a refund happens matters:

- A refund 55s into the cycle only moves the next ultimate up by ~5s.
- A refund 1s in is worth a whole extra ultimate.

The bot therefore holds normal attacks while the ultimate recharges, fires the ultimate the moment it's ready, then spends every held attack, one every 0.8s (`OMHP_ATTACK_GAP`). A refund during that spend fires the next ultimate immediately and restarts the cycle. Holding never goes past the attack cap (20), so no recharge is wasted, and the bot wakes exactly when the ultimate or the next attack is due instead of up to 5s late.

| Strategy (model, 1.5% refund, ~1,000-damage ultimates) | Ultimates/h | Damage |
| --- | --- | --- |
| Attack as they recharge, ultimate noticed ~4s late (before) | 62.2 | baseline |
| Same, waking exactly when the ultimate is ready | 65.0 | +3.5% |
| **Hold until the ultimate, then spend everything** | **70.1** | **+9.9%** |

Against a mock server with the same mechanics sped up 5× (12s timer, 10% refunds), holding got 12/9/9 ultimates per minute against 9/8/8 without, with identical refund luck. Set `OMHP_ULT_HOLD=0` to attack as attacks recharge instead.

If the server refuses an ultimate, the bot retries after 5s, doubling on each refusal in a row up to `OMHP_ULT_BACKOFF` (600s). While the ultimate is backed off, attacks aren't held.

### Regenerated ultimates and attacks

Normally you get one ultimate per boss, but the admin can grant more, and so can some attack effects (the `refund` proc, "ULT RECHARGED!"). Attacks can also go above the 20 cap through bonus attacks from the admin or from procs (for example the `saved` proc, "FREE ATTACK!").

The bot doesn't track any of these counts itself. It reads `ultimate_available` and `attacks_left` from the latest server state on every loop, so a regenerated ultimate or bonus attack gets used on the next pass. Grants that arrive while the bot is sleeping are seen at the next refresh, which is at most one recharge interval later.

### Buying loot boxes

By default (`OMHP_BUY_BOX=max`) the bot buys the **most expensive box in the shop** whenever your shards cover it. It reads the live prices from `me.shop.boxes`, which include any price changes the admin makes, so a new top-tier box is picked up automatically, and the log notes whenever the target changes. It saves up for that box rather than buying cheaper ones, and keeps buying as long as you can afford another.

Current shop (as of 2026-10-04):

| Box | Price | Contents |
| --- | --- | --- |
| **Void Reliquary** | 500 | epic 42%, legendary 40%, mythic 14%, **godly 4%** |
| Occult Ossuary | 250 | epic 54.4%, legendary 23.6%, mythic 4.7%, godly 0.9%, scroll 16.4% |
| Cursed Casket | 100 | rare 24.3%, epic 31.3%, legendary 11.8%, mythic 2.1%, godly 0.1%, 3 crit charges 23.2%, scroll 7.1% |
| Iron Chest | 30 | 2 attacks 35%, uncommon–epic items, 2 crit charges 18.8% |
| Wooden Crate | 10 | 1–2 attacks 49%, common–rare items, 1 crit charge 18.5% |

- To buy a specific box instead, set `OMHP_BUY_BOX` to its ID (for example `occult_ossuary`). To turn buying off, set it to an empty string (`OMHP_BUY_BOX=`).
- If `me.shop` is missing, the bot uses the price list above.
- If the server refuses a purchase, the bot doesn't retry until your shard count changes, and buying is disabled for 5 minutes.

### Session summary

Every attack, scroll use and purchase is appended to `logs/session-YYYYMMDD-HHMMSS.jsonl`. When the bot stops (Ctrl-C, `kill`, or `systemctl stop`), it prints a summary built from that file:

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
| `OMHP_ATTACK_GAP` | `0.8`                       | Minimum seconds between normal attacks (send to send); doesn't apply to the ultimate, scrolls or purchases |
| `OMHP_DEAD_POLL`  | `30`                        | Seconds between checks while no boss is alive |
| `OMHP_BUY_BOX`    | `max`                       | `max` = the shop's most expensive box; or a box ID; empty disables buying |
| `OMHP_SCROLLS`    | `0`                         | `1` = use scrolls as soon as you have them |
| `OMHP_CAPTCHA_POLL` | `30`                      | Seconds between checks while a captcha waits for you |
| `OMHP_NOTIFY`     | `1`                         | macOS notification when a captcha appears; `0` turns it off |
| `OMHP_ULT_HOLD`   | `1`                         | Hold attacks while the ultimate recharges, spend them right after it; `0` attacks as they recharge |
| `OMHP_ULT_BACKOFF`| `600`                       | Longest wait after repeated ultimate refusals (starts at 5s) |
| `OMHP_LOG_DIR`    | `./logs` (next to the script) | Where session logs are written            |

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
| `POST /api/scrolls/use`    | `{ "scroll_id": string }`              |
| `GET  /api/state`          | (none; public; includes `server_time` and `boss`) |
| `POST /api/attack`         | `{ "kind": "normal" \| "ultimate", "request_id": uuid }` |
| `POST /api/boxes/open`     | `{ "box_id": string, "request_id": uuid }` |
| `POST /api/shop/buy`       | `{ "box_id": string }`                 |
| `POST /api/me/equip`       | `{ "item_id": string \| null, "slot"?: string }` |

All authenticated calls send `Authorization: Bearer <token>`. The `request_id` makes a retry safe: if you resend the same ID, the server returns the original result instead of acting twice.

## Error handling and game changes

The game changes often (the ultimate was removed mid-boss, fields get added and renamed). The bot is built so that whatever breaks, it falls back to **normal attacks**:

- **Optional actions back off.** The ultimate, scrolls and buying are all optional. If one errors, it's disabled for a while (ultimate from 5s doubling up to 10 min, buying 5 min, each refused scroll 2 min), and the same pass carries on to a normal attack. A broken feature costs one attempt per backoff, never all your attacks. Optional actions don't wait after an error.
- **Missing or renamed fields default to attacking.** If `attacks_left` is missing, the bot attacks anyway and lets the server answer `NO_ATTACKS`. It then waits one recharge interval (`recharge_seconds`, or 5s) before trying again. If `next_attack_at` is missing, it waits the recharge interval. A response without `me` triggers a fresh `/api/me`.
- **Non-JSON responses** (proxy error pages, moved endpoints) are turned into an error with the HTTP status, so the bot never tries to parse HTML.
- **No tight loops.** Every failure path waits at least a moment.

| Error                          | Behavior                    |
| ------------------------------ | --------------------------- |
| `UNAUTHENTICATED` / 401        | Exit (bad token)            |
| `NEED_NAME`                    | Exit (set a name in the web UI) |
| Optional action fails          | Disable it for a while; attack normally this pass |
| `NO_ATTACKS`                   | Wait one recharge interval  |
| Network error, 429, 5xx (normal attack) | Wait 3s, refresh, continue |
| Anything else                  | Refresh state, wait 1s, continue |

Tested against a server with renamed fields, a refused ultimate, HTML errors from scrolls, boxes and random attacks, a closed shop, and a broken mod value: each broken action was tried once and disabled within the first second, and the bot kept attacking.

## Notes

- Your token is your whole account. Don't commit it or share it.
- Automated play may be against the game's rules. Use it at your own discretion.
