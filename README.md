# one-million-hp-bot

A small bash bot that plays [ONE MILLION HP](https://onemillionhp.com) for you.

## What it does

Every API response includes your updated player state (`me`), and the bot picks its next move from it:

1. **Ultimate available** → use it.
2. **Loot box in the bag** → open it.
3. **Enough shards for a Cursed Casket** (100 by default) → buy one. The next pass opens it through step 2.
4. **Attacks left** → attack.
5. **Nothing to do** → sleep until the next attack recharges (`next_attack_at`), then refresh.
6. **Boss not alive** → check again every 30s until the next boss spawns.

Attacks recharge one every 5s, up to 20 stored.

### Regenerated ultimates and attacks

Normally you get one ultimate per boss, but the admin can grant more, and so can some attack effects (the `refund` proc, "ULT RECHARGED!"). Attacks can also go above the 20 cap through bonus attacks from the admin or from procs (for example the `saved` proc, "FREE ATTACK!").

The bot doesn't track any of these counts itself. It reads `ultimate_available` and `attacks_left` from the latest server state on every loop, so a regenerated ultimate or bonus attack gets used on the next pass. Grants that arrive while the bot is sleeping are seen at the next refresh, which is at most one recharge interval later.

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
| `OMHP_DEAD_POLL`  | `30`                        | Seconds between checks while no boss is alive |
| `OMHP_BUY_BOX`    | `cursed_casket`             | Box to buy with shards; empty disables buying |
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
| `GET  /api/state`          | (none; public; includes `server_time` and `boss`) |
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
