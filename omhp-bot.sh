#!/usr/bin/env bash
# Auto-player for https://onemillionhp.com
#
# Loop, driven by the `me` object every API response returns:
#   1. ultimate available -> use it
#   2. loot box in bag    -> open it
#   3. enough shards      -> buy a box (default: cursed casket), opened by step 2
#   4. attacks left       -> attack
#   else sleep until the next attack recharges (or poll while the boss is dead)
#
# Live feed: omhp-live.mjs (Node 22+) follows the game's WebSocket stream and
# keeps the boss HP, the other players' damage rate and the stream lag in a
# file, which hoarding reads every OMHP_LIVE_POLL seconds. Without Node, or if
# the feed drops, hoarding falls back to polling /api/state.
#
# Last-hit hoarding: once the boss is at or below OMHP_HOARD_PCT of its HP,
# attacks are held back (the ultimate is still used right away). Banked loot
# boxes (OMHP_BANK_BOXES: wooden crates and iron chests) stay unopened until
# the kill attempt itself: the game spends crit charges on the very next
# attacks, so charges must not exist before the burst. The bot watches the
# boss HP; when a burst (with the charges the bank will likely produce) can
# finish the boss, it fires one burst that weaves box opens with attacks
# (open, attack, open, attack...), so each charge is created just before the
# attacks that use it. Opens and attacks are separate endpoints with their
# own rate limits, so weaving costs no extra time. At the attack cap it spends
# one at a time so recharge isn't wasted, unless that would burn a crit charge.
#
# Every action is appended to logs/session-*.jsonl; stopping the bot (Ctrl-C,
# SIGTERM) prints a summary built from that file.
#
# Usage:
#   OMHP_TOKEN=xxxx ./omhp-bot.sh
#   ./omhp-bot.sh --summary logs/session-....jsonl   # re-print an old summary
# Get the token from the game tab's devtools console:
#   localStorage.getItem("omhp.token")
#
# Requires: curl, jq, uuidgen (all stock on macOS except jq: brew install jq)

set -uo pipefail

API="${OMHP_API:-https://onemillionhp.com}"
PAUSE="${OMHP_PAUSE:-0.4}"        # seconds between consecutive actions
DEAD_POLL="${OMHP_DEAD_POLL:-30}" # seconds between checks while no boss is alive
BUY_BOX="${OMHP_BUY_BOX-cursed_casket}" # box to buy with shards; empty disables buying
HOARD_PCT="${OMHP_HOARD_PCT:-5}"      # start hoarding at this % boss HP; 0 disables
BANK_BOXES="${OMHP_BANK_BOXES-wooden_crate,iron_chest}" # boxes kept unopened until hoarding
BANK_MAX="${OMHP_BANK_MAX:-60}"       # open banked boxes beyond this many
HOARD_POLL="${OMHP_HOARD_POLL:-1}"    # seconds between boss HP checks while hoarding
HIT_EST_DEFAULT="${OMHP_HIT_EST:-20}" # per-hit damage guess until the logs have data
MARGIN_SD="${OMHP_MARGIN_SD:-1.5}"    # fire when HP <= burst mean - this many sd (1.5 = ~93% sure)
LIVE="${OMHP_LIVE:-1}"                # 1 = use the WebSocket feed when Node 22+ is available
LIVE_POLL="${OMHP_LIVE_POLL:-0.2}"    # seconds between live-feed reads while hoarding
FIRE_LEAD="${OMHP_FIRE_LEAD:-0.3}"    # seconds for our attacks to reach the server
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOG_DIR="${OMHP_LOG_DIR:-$SCRIPT_DIR/logs}"

log() { printf '%s  %s\n' "$(date +%H:%M:%S)" "$*"; }

# Sleep that a signal can interrupt (a plain foreground sleep delays traps).
nap() { sleep "$1" & wait $! 2>/dev/null; }

# ---------------------------------------------------------------- summary

# summarize SESSION_LOG -> human-readable report on stdout
summarize() {
  jq -rs '
    def c: floor as $n | if $n < 1000 then "\($n)" else "\(($n / 1000 | floor) | c),\((1000 + $n % 1000) | tostring | .[1:])" end;
    def avg: if length == 0 then "-" else (add / length * 10 | round / 10 | tostring) end;
    def dur: floor as $s | "\($s / 3600 | floor)h \($s % 3600 / 60 | floor)m \($s % 60)s";

    (map(select(.t == "start"))[0] // {}) as $start
    | (map(select(.t == "stop"))[-1].ts // now) as $end
    | map(select(.t == "attack")) as $atk
    | ($atk | map(select(.kind == "normal" and (.crit | not)) | .damage)) as $norm
    | ($atk | map(select(.kind == "normal" and .crit) | .damage)) as $crit
    | ($atk | map(select(.kind == "ultimate") | .damage)) as $ult
    | map(select(.t == "box")) as $boxes
    | map(select(.t == "buy")) as $buys
    | map(select(.t == "defeat")) as $kills
    | $start.content as $ct
    | [
        "",
        "=============== SESSION SUMMARY ===============",
        "Duration        \(($end - ($start.ts // $end)) | dur)",
        "Attacks         \($atk | length | c)   (normal \($norm | length | c), crit \($crit | length | c), ultimate \($ult | length | c))",
        "Total damage    \($atk | map(.damage) | add // 0 | c)",
        "Avg damage      normal \($norm | avg)   crit \($crit | avg)   ultimate \($ult | avg)",
        "Last hits       \($kills | map(select(.mine)) | length) of \($kills | length) boss kill(s) seen",
        "Loot boxes      \($boxes | length) opened\(if ($buys | length) > 0 then "  (\($buys | length) bought for \($buys | map(.price) | add | c) shards)" else "" end)",
        ( $boxes
          | group_by(.box_id)
          | sort_by(-(($ct.box_rank // {})[.[0].box_id // ""] // -1))
          | .[]
          | . as $g
          | ($g | map(.result)) as $r
          | "  \(($ct.box_names // {})[$g[0].box_id // ""] // $g[0].box_id) x\($g | length)",
            ( $r | map(select(.kind == "item"))
              | group_by(.rarity)
              | sort_by(-(($ct.rarity_rank // {})[.[0].rarity // ""] // -1))
              | .[]
              | "      \(.[0].rarity // "?" | ascii_upcase) x\(length): "
                + (group_by(.item_name) | map("\(.[0].item_name // .[0].item_id)\(if length > 1 then " x\(length)" else "" end)\(if any(.autosold) then " (auto-sold)" else "" end)") | join(", ")) ),
            ( $r | map(select(.kind == "attacks")) | select(length > 0)
              | "      attacks +\(map(.amount // 1) | add)" ),
            ( $r | map(select(.kind == "next_crit")) | select(length > 0)
              | "      crit charges +\(map(.amount // 1) | add)" ),
            ( $r | map(select(.kind == "ultimate")) | select(length > 0)
              | "      ultimate recharge x\(length)" ),
            ( $r | map(select(.kind as $k | ["item", "attacks", "next_crit", "ultimate"] | index($k) | not)) | select(length > 0)
              | "      other: \(map(.kind) | join(", "))" )
        ),
        "==============================================="
      ]
    | .[]' "$1"
}

if [[ ${1:-} == --summary ]]; then
  summarize "${2:?usage: $0 --summary logs/session-....jsonl}"
  exit
fi

TOKEN="${OMHP_TOKEN:?set OMHP_TOKEN (localStorage.getItem(\"omhp.token\") in the game tab)}"

mkdir -p "$LOG_DIR"
SESSION_LOG="$LOG_DIR/session-$(date +%Y%m%d-%H%M%S).jsonl"

# record JSON -> one line in the session log, stamped with the time
record() { jq -c --argjson ts "$(date +%s)" '. + {ts: $ts}' <<<"$1" >>"$SESSION_LOG"; }

# ---------------------------------------------------------------- api

# api METHOD PATH [JSON_BODY] -> prints body; returns 0 on 2xx, 1 otherwise
api() {
  local method=$1 path=$2 body=${3:-} out code
  local args=(-sS -X "$method" -H "Authorization: Bearer $TOKEN" -w $'\n%{http_code}' --max-time 20)
  [[ -n $body ]] && args+=(-H "Content-Type: application/json" -d "$body")
  out=$(curl "${args[@]}" "$API$path") || { echo '{"error":{"code":"NETWORK"}}'; return 1; }
  code=${out##*$'\n'}
  printf '%s' "${out%$'\n'*}"
  [[ $code == 2* ]]
}

rid() { uuidgen | tr 'A-Z' 'a-z'; }

# Server clock offset, so we sleep exactly until next_attack_at.
server_now() {
  api GET /api/state | jq -r '.server_time // empty'
}
SKEW=$(awk -v s="$(server_now)" -v l="$(date +%s)" 'BEGIN{ if (s=="") print 0; else printf "%.3f", s-l }')

# Item names/rarities and box tiers, for labelling loot in the log and summary.
CONTENT=$(api GET /api/content | jq -c '{
  items: ([.items[]? | {key: .id, value: {name, rarity}}] | from_entries),
  box_names: ([.boxes[]? | {key: .id, value: .name}] | from_entries),
  box_rank: ([.boxes // [] | to_entries[] | {key: .value.id, value: .key}] | from_entries),
  rarity_rank: ([.rarities[]? | {key: .id, value: .rank}] | from_entries),
  box_crit: ([.boxes[]? | {key: .id, value: ([.odds[]? | select(.kind == "next_crit")]
    | {mean: (map(.chance * (.amount // 1)) | add // 0), m2: (map(.chance * (.amount // 1) * (.amount // 1)) | add // 0)})}] | from_entries),
  box_atk: ([.boxes[]? | {key: .id, value: ([.odds[]? | select(.kind == "attacks") | .chance * (.amount // 1)] | add // 0)}] | from_entries)
}' 2>/dev/null) || CONTENT='{}'
[[ -n $CONTENT ]] || CONTENT='{}'

ME=""       # latest `me` JSON
BOSS=""     # latest `boss` JSON (status alive/…)

refresh() {
  local r
  if r=$(api GET /api/me); then ME=$r; else log "GET /api/me failed: $r"; return 1; fi
  BOSS=$(api GET /api/state | jq -c '.boss // {}')
}

error_code() { jq -r '.error.code // "UNKNOWN"' <<<"$1"; }

handle_error() {
  local what=$1 res=$2 code
  code=$(error_code "$res")
  log "$what failed: $code $(jq -r '.error.message // empty' <<<"$res")"
  case $code in
    NEED_NAME) log "Pick a name in the web UI first."; exit 1 ;;
    HTTP_401|UNAUTHORIZED|UNAUTHENTICATED) log "Token rejected."; exit 1 ;;
    NETWORK|HTTP_429|HTTP_5*) nap 5 ;;
  esac
  refresh || nap 5
}

stats() {
  jq -r '"attacks \(.attacks_left)/\(.attacks_per_day)  boss dmg \(.boss_damage // 0)  boxes \([(.boxes // [])[] | .count // 1] | add // 0)  crits \(.next_crits // 0)  shards \(.shards // 0)  ult \(if .ultimate_available then "READY" elif .ultimate_used then "spent" else "-" end)"' <<<"$ME"
}

# ---------------------------------------------------------------- actions

attack_body() { jq -nc --arg k "$1" --arg r "$(rid)" '{kind:$k, request_id:$r}'; }

do_attack() { # kind = normal | ultimate
  local kind=$1 res
  if res=$(api POST /api/attack "$(attack_body "$kind")"); then
    on_attack "$kind" "$res"
  else
    handle_error "attack($kind)" "$res"
  fi
}

# on_attack KIND RESPONSE [quiet]: take the new state, log and record the hit
on_attack() {
  local kind=$1 res=$2 quiet=${3:-}
  ME=$(jq -c '.me' <<<"$res")
  BOSS=$(jq -c '.boss // {}' <<<"$res")
  record "$(jq -c --arg k "$kind" '.attack as $a | {t: "attack", kind: $k, damage: ($a.damage // 0),
    crit: ($a.crit // false), item_id: $a.item_id, procs: ($a.procs // {}), boss_seq: .boss.seq, boss_hp: .boss.hp}' <<<"$res")"
  jq -r --arg k "$kind" '.attack as $a | "\($k | ascii_upcase): \($a.damage) dmg" +
      (if $a.crit then " CRIT" else "" end) +
      (if $a.item_id then "  +item \($a.item_id)" else "" end) +
      (if ($a.procs.box_id // null) then "  +box \($a.procs.box_id)" else "" end) +
      (($a.procs // {}) | to_entries | map(select(.key != "box_id" and .value)) | map("  [" + .key + "]") | join(""))' <<<"$res" |
    while read -r line; do log "$line"; done
  [[ -n $quiet ]] || log "  $(stats)"
}

open_body() { jq -nc --arg b "$1" --arg r "$(rid)" '{box_id:$b, request_id:$r}'; }

# on_box_open BOX RESPONSE: take the new state and record what was inside
on_box_open() {
  ME=$(jq -c '.me' <<<"$2")
  record "$(jq -c --arg b "$1" --argjson ct "$CONTENT" '.result as $r | ($ct.items // {})[$r.item_id // ""] as $i |
    {t: "box", box_id: $b, result: ($r + {item_name: $i.name, rarity: ($r.rarity // $i.rarity)})}' <<<"$2")"
}

do_open_box() {
  local box=$1 res
  if res=$(api POST /api/boxes/open "$(open_body "$box")"); then
    on_box_open "$box" "$res"
    log "OPENED $box -> $(jq -c '.result' <<<"$res")"
  else
    handle_error "open($box)" "$res"
  fi
}

# Price of BUY_BOX: me.shop has the admin's price changes applied.
box_price() { jq -r --arg b "$BUY_BOX" '.shop.boxes[$b] // 100' <<<"$ME"; }

# Set after a refused purchase so we don't retry until the shard count changes.
BUY_BLOCKED_AT=""

can_buy() {
  [[ -n $BUY_BOX ]] || return 1
  local shards
  shards=$(jq -r '.shards // 0' <<<"$ME")
  [[ $shards != "$BUY_BLOCKED_AT" ]] && (( shards >= $(box_price) ))
}

do_buy_box() {
  local res shards price
  shards=$(jq -r '.shards // 0' <<<"$ME")
  price=$(box_price)
  if res=$(api POST /api/shop/buy "$(jq -nc --arg b "$BUY_BOX" '{box_id:$b}')"); then
    ME=$(jq -c '.me' <<<"$res")
    BUY_BLOCKED_AT=""
    record "$(jq -nc --arg b "$BUY_BOX" --argjson p "$price" '{t: "buy", box_id: $b, price: $p}')"
    log "BOUGHT $BUY_BOX for $price shards  ($(jq -r '.shards // 0' <<<"$ME") left)"
  else
    BUY_BLOCKED_AT=$shards
    handle_error "buy($BUY_BOX)" "$res"
  fi
}

# ---------------------------------------------------------------- last-hit hoarding

# Is the boss at or below HOARD_PCT of its max HP?
hoarding() {
  jq -e --argjson pct "$HOARD_PCT" '$pct > 0 and .status == "alive" and .hp != null and .max_hp != null
    and .hp <= .max_hp * $pct / 100' <<<"$BOSS" >/dev/null
}

# Damage estimates from recent attacks across all session logs, refreshed at
# most once a minute: mean and spread of non-crit normal hits and of crits.
HIT_MEAN=$HIT_EST_DEFAULT HIT_SD=0 CRIT_MEAN=$((HIT_EST_DEFAULT * 12)) CRIT_SD=0 EST_AT=0

update_estimates() {
  local now; now=$(date +%s)
  (( now - EST_AT < 60 )) && return
  EST_AT=$now
  local est
  est=$(ls -1t "$LOG_DIR"/session-*.jsonl 2>/dev/null | head -5 | xargs tail -q -n 20000 2>/dev/null | jq -rs \
    --argjson d "$HIT_EST_DEFAULT" '
    [.[] | select(.t == "attack" and .kind == "normal")] as $a
    | ($a | map(select(.crit | not) | .damage) | .[-3000:]) as $h
    | ($a | map(select(.crit) | .damage) | .[-300:]) as $c
    | def sd($x; $m): $x | map(. * .) | add / length - $m * $m | if . < 0 then 0 else sqrt end;
    (if ($h | length) > 20 then ($h | add / length) else $d end) as $m
    | (if ($h | length) > 20 then sd($h; $m) else 0 end) as $sd
    | (if ($c | length) > 10 then ($c | add / length) else $m * 12 end) as $cm
    | (if ($c | length) > 10 then sd($c; $cm) else 0 end) as $csd
    | "\($m * 10 | round / 10) \($sd * 10 | round / 10) \($cm | round) \($csd | round)"' 2>/dev/null)
  [[ -n $est ]] && read -r HIT_MEAN HIT_SD CRIT_MEAN CRIT_SD <<<"$est"
}

# box_to_open: the next box to open, if any. Banked types stay shut (they're
# woven into the kill burst) unless the bank passes BANK_MAX;
# everything else opens right away.
box_to_open() {
  jq -er --arg bank "$BANK_BOXES" --argjson all false --argjson max "$BANK_MAX" '
    ($bank | split(",") | map(select(. != ""))) as $bk
    | (.boxes // []) as $b
    | ($b | map(select(.box_id as $i | $bk | index($i)))) as $banked
    | ($banked | map(.count // 1) | add // 0) as $held
    | ($b | map(select(.box_id as $i | ($bk | index($i) | not))) | .[0].box_id)
      // (if $all or $held > $max then $banked[0].box_id else empty end)' <<<"$ME"
}

# bank_estimate: "COUNT CHARGES VAR ATTACKS" = banked boxes, the crit charges
# opening them all is expected to yield (from the game's box odds) and its
# variance, and the attacks they're expected to add.
bank_estimate() {
  jq -r --arg bank "$BANK_BOXES" --argjson ct "$CONTENT" '($bank | split(",")) as $bk
    | [(.boxes // [])[] | select(.box_id as $i | $bk | index($i))] as $b
    | ($b | map(.count // 1) | add // 0) as $n
    # Fallback odds (from /api/content at the time of writing) if content failed to load.
    | {wooden_crate: {mean: 0.185, m2: 0.185}, iron_chest: {mean: 0.375, m2: 0.75}} as $fb
    | {wooden_crate: 0.598, iron_chest: 0.7} as $fba
    | ($b | map((($ct.box_crit // {})[.box_id] // $fb[.box_id] // {mean: 0, m2: 0}) as $o | {n: (.count // 1), mean: $o.mean, var: ($o.m2 - $o.mean * $o.mean)})) as $x
    | ($x | map(.n * .mean) | add // 0) as $m
    | ($x | map(.n * .var) | add // 0) as $v
    | ($b | map((($ct.box_atk // {})[.box_id] // $fba[.box_id] // 0) * (.count // 1)) | add // 0) as $atk
    | "\($n) \($m * 100 | round / 100) \($v * 100 | round / 100) \($atk | floor)"' <<<"$ME"
}

# How many boxes are banked (for the status line).
banked_count() {
  jq -r --arg bank "$BANK_BOXES" '($bank | split(",")) as $bk
    | [(.boxes // [])[] | select(.box_id as $i | $bk | index($i)) | .count // 1] | add // 0' <<<"$ME"
}

# burst N: fire N attacks at once, woven with opening every banked box
# (open, attack, open, attack...): each crit charge lands just before the
# attacks that use it. Attack requests beyond what we end up having are
# rejected with NO_ATTACKS.
burst() {
  local n=$1 dir i=0 j kind f id ids pids=() t0
  t0=$(now_f)
  ids=($(jq -r --arg bank "$BANK_BOXES" '($bank | split(",")) as $bk
    | (.boxes // [])[] | select(.box_id as $i | $bk | index($i)) | .box_id as $id | range(.count // 1) | $id' <<<"$ME"))
  dir=$(mktemp -d)
  log "BURST: $n attack(s) woven with ${#ids[@]} banked box(es), $(jq -r '.next_crits // 0' <<<"$ME") crit charge(s) at $(jq -r '.hp' <<<"$BOSS") HP"
  for ((j = 0; j < n || j < ${#ids[@]}; j++)); do
    if (( j < ${#ids[@]} )); then
      id=${ids[$j]}
      { api POST /api/boxes/open "$(open_body "$id")" >"$dir/box.$id.$j" || mv "$dir/box.$id.$j" "$dir/boxerr.$id.$j"; } &
      pids+=($!)
    fi
    if (( j < n )); then
      { api POST /api/attack "$(attack_body normal)" >"$dir/atk.$j" || mv "$dir/atk.$j" "$dir/atkerr.$j"; } &
      pids+=($!)
    fi
  done
  (( ${#pids[@]} )) && wait "${pids[@]}"
  local burst_s; burst_s=$(awk -v a="$t0" -v b="$(now_f)" 'BEGIN{printf "%.2f", b-a}')

  # Box results in one jq pass (fast; the boss may die any moment).
  if compgen -G "$dir/box.*" >/dev/null; then
    (cd "$dir" && for f in box.*; do id=${f#box.}; jq -c --arg b "${id%.*}" '{b: $b, r: .result}' "$f"; done) |
      jq -c --argjson ct "$CONTENT" --argjson ts "$(date +%s)" '.r as $r | ($ct.items // {})[$r.item_id // ""] as $i |
        {t: "box", box_id: .b, result: ($r + {item_name: $i.name, rarity: ($r.rarity // $i.rarity)}), ts: $ts}' >>"$SESSION_LOG"
  fi
  local opened crits_made boxerr
  opened=$(ls "$dir" | grep -c '^box\.')
  boxerr=$(ls "$dir" | grep -c '^boxerr\.')
  crits_made=$( (cd "$dir" && cat box.* 2>/dev/null) | jq -s '[.[] | .result | select(.kind == "next_crit") | .amount // 1] | add // 0')

  local failed=() hits=0 crit_hits=0
  for f in "$dir"/atk.*; do
    [[ -e $f ]] || continue
    on_attack normal "$(cat "$f")" quiet
    hits=$((hits + 1))
    [[ $(jq -r '.attack.crit // false' <"$f") == true ]] && crit_hits=$((crit_hits + 1))
  done
  for f in "$dir"/atkerr.*; do
    [[ -e $f ]] && failed+=("$(jq -r '.error.code // "?"' <"$f")")
  done
  rm -rf "$dir"
  log "  burst took ${burst_s}s: $hits hit(s), $crit_hits crit; opened $opened box(es)$( (( boxerr )) && echo " ($boxerr failed)") making $crits_made crit charge(s)"
  (( ${#failed[@]} )) && log "  ${#failed[@]} attack(s) rejected: $(printf '%s\n' "${failed[@]}" | sort | uniq -c | awk '{printf "%s%s x%s", (NR>1?", ":""), $2, $1}')"
  refresh || nap 5
  log "  $(stats)"
}

# ---- live feed

LIVE_FILE="" LIVE_RATE=0 LIVE_LAG=0 LIVE_GIFTS=0 # LIVE_RATE: steady rate, big hits left out

start_live() {
  [[ $LIVE == 1 ]] || { log "Live feed: off (OMHP_LIVE=$LIVE)"; return; }
  if ! command -v node >/dev/null || ! node -e 'process.exit(typeof WebSocket === "function" ? 0 : 1)' 2>/dev/null; then
    log "Live feed: off (needs Node 22+); hoarding will poll the API every ${HOARD_POLL}s"
    return
  fi
  LIVE_FILE="$LOG_DIR/.live-$$.json"
  OMHP_API=$API OMHP_TOKEN=$TOKEN OMHP_SKEW=$SKEW OMHP_PARENT_PID=$$ \
    OMHP_PLAYER_ID=$(jq -r '.id // ""' <<<"$ME") \
    node "$SCRIPT_DIR/omhp-live.mjs" "$LIVE_FILE" 2>>"$LOG_DIR/live.err" &
  log "Live feed: on (WebSocket)"
}

# live_read: load boss/rate/lag from the feed if the helper is up and connected
live_read() {
  [[ -n $LIVE_FILE && -s $LIVE_FILE ]] || return 1
  local j
  j=$(jq -c 'select(.connected and (now - .written) < 3 and .boss != null)' "$LIVE_FILE" 2>/dev/null)
  [[ -n $j ]] || return 1
  BOSS=$(jq -c '.boss' <<<"$j")
  read -r LIVE_RATE LIVE_LAG LIVE_GIFTS < <(jq -r '"\(.steady // .rate // 0) \(.lag // 0) \(.gifts // 0)"' <<<"$j")
}

# ---- hoarding

LAST_HOARD_KEY="" LAST_HOARD_LOG=0
PREV_HP="" PREV_T="" RATE=0 RATES=""  # polling mode: HP drop rate (HP/s), median of the last 5 samples
ME_AT=0 SEEN_GIFTS=0           # live mode: when /api/me was last fetched, gifts seen

now_f() { perl -MTime::HiRes=time -e 'printf "%.3f", time'; }

track_rate() { # track_rate HP
  local now x
  now=$(now_f)
  if [[ -n $PREV_HP ]]; then
    x=$(awk -v a="$PREV_HP" -v b="$1" -v t0="$PREV_T" -v t1="$now" 'BEGIN{ dt = t1 - t0; if (dt <= 0 || b > a) print ""; else printf "%.1f", (a - b) / dt }')
    if [[ -n $x ]]; then
      # A median ignores the occasional ultimate-sized jump (see omhp-live.mjs).
      RATES=$(printf '%s\n' $RATES "$x" | tail -5 | tr '\n' ' ')
      RATE=$(printf '%s\n' $RATES | sort -n | awk '{ v[NR] = $1 } END { print v[int((NR + 1) / 2)] }')
    fi
  fi
  PREV_HP=$1 PREV_T=$now
}

# In live mode the boss comes from the feed; /api/me is only re-fetched when
# an attack has recharged, a gift arrived, or 15s have passed.
refresh_me_if_due() {
  local due
  due=$(jq -r --argjson skew "$SKEW" --argjson at "$ME_AT" --argjson g "$LIVE_GIFTS" --argjson sg "$SEEN_GIFTS" '
    (now - $at > 15) or ($g != $sg) or ((.next_attack_at // 0) > 0 and now + $skew >= .next_attack_at)' <<<"$ME")
  [[ $due == true ]] || return 0
  local r
  r=$(api GET /api/me) && ME=$r
  ME_AT=$(now_f) SEEN_GIFTS=$LIVE_GIFTS
}

hoard_step() {
  local hp left per crits plan rate lag poll mode banked bankest bankvar bankatk
  if live_read; then
    mode=live rate=$LIVE_RATE lag=$LIVE_LAG poll=$LIVE_POLL
    hoarding || return 0 # the feed says the boss died or left range
  else
    mode=poll poll=$HOARD_POLL lag=0
    track_rate "$(jq -r '.hp' <<<"$BOSS")"
    rate=$RATE
  fi
  hp=$(jq -r '.hp' <<<"$BOSS")
  left=$(jq -r '.attacks_left // 0' <<<"$ME")
  per=$(jq -r '.attacks_per_day // 20' <<<"$ME")
  crits=$(jq -r '.next_crits // 0' <<<"$ME")
  read -r banked bankest bankvar bankatk <<<"$(bank_estimate)"
  update_estimates

  # What we can deal in one burst ($cap), estimated as one sum: N attacks
  # (held plus those the bank is expected to add), of which C carry crit
  # charges (ours plus the bank's expected yield). Mean = C crits + (N - C)
  # normal hits; the variance adds each hit's spread and the uncertainty in
  # how many charges the bank gives. $cap = mean - MARGIN_SD standard
  # deviations. (Counting each crit at a low percentile instead made the
  # bot wait for HP that other players' ultimates never left us.) The
  # ultimate isn't counted: it's used as soon as it's ready.
  # The HP we see is `lag` seconds old and our attacks take FIRE_LEAD to land;
  # others keep hitting meanwhile. $land = expected HP when the burst arrives.
  #   fire N      $land is within $cap: fire the woven burst now. N = attacks
  #               held plus those the bank is expected to add
  #   timed S N   it will be before the next check: sleep S seconds, then fire
  #   spend       at the attack cap with no crit charges: use one so recharge
  #               isn't wasted (with charges, keep them for the burst)
  #   wait CAP    keep watching
  plan=$(jq -nr --argjson hp "$hp" --argjson left "$left" --argjson per "$per" --argjson crits "$crits" \
    --argjson bankest "$bankest" --argjson bankvar "$bankvar" --argjson bankatk "$bankatk" \
    --argjson mean "$HIT_MEAN" --argjson sd "$HIT_SD" --argjson cmean "$CRIT_MEAN" --argjson csd "$CRIT_SD" \
    --argjson z "$MARGIN_SD" --argjson rate "$rate" \
    --argjson lead "$(awk -v a="$lag" -v b="$FIRE_LEAD" 'BEGIN{print a+b}')" --argjson poll "$poll" '
    ($left + $bankatk) as $n
    | ([$crits + $bankest, $n] | min) as $c
    | ($c * $cmean + ($n - $c) * $mean) as $bm
    | ($c * $csd * $csd + ($n - $c) * $sd * $sd + $bankvar * ($cmean - $mean) * ($cmean - $mean)) as $bv
    | ([$bm - $z * ($bv | sqrt), 0] | max | floor) as $cap
    | ($hp - $rate * $lead) as $land
    | if $left <= 0 then "wait \($cap)"
      elif $land <= $cap then "fire \($n)"
      elif $rate > 0 and ($land - $cap) / $rate < $poll then "timed \(($land - $cap) / $rate * 1000 | floor / 1000) \($n)"
      elif $left >= $per and $crits == 0 then "spend"
      else "wait \($cap)" end')

  case $plan in
    fire*) burst "${plan#fire }"; PREV_HP="" ME_AT=$(now_f) ;;
    timed*)
      set -- ${plan#timed }
      log "HOARD: boss in reach in ${1}s at -$rate/s; timing the burst"
      nap "$1"
      burst "$2"; PREV_HP="" ME_AT=$(now_f) ;;
    spend)
      log "HOARD: at the attack cap ($left), spending one so recharge isn't wasted"
      do_attack normal; PREV_HP="" ME_AT=$(now_f) ;;
    wait*)
      # Log when our holdings change, otherwise at most every 5s.
      local key="$left/$crits/$banked" t
      t=$(date +%s)
      if [[ $key != "$LAST_HOARD_KEY" ]] || (( t - LAST_HOARD_LOG >= 5 )); then
        log "HOARD[$mode]: boss $hp HP (-$rate/s, lag ${lag}s), holding $left attack(s) + $crits crit charge(s) + $banked banked box(es) (~$bankest charges), can hit ~${plan#wait } (hit $HIT_MEAN±$HIT_SD, crit $CRIT_MEAN±$CRIT_SD)"
        LAST_HOARD_KEY=$key LAST_HOARD_LOG=$t
      fi
      nap "$poll"
      if [[ $mode == live ]]; then refresh_me_if_due; else refresh || nap 5; fi ;;
  esac
}

# Record each boss defeat once, noting whether we landed the killing blow.
LAST_DEFEAT_SEQ=""
note_defeat() {
  local seq killer me
  seq=$(jq -r '.seq // ""' <<<"$BOSS")
  [[ -z $seq || $seq == "$LAST_DEFEAT_SEQ" ]] && return
  LAST_DEFEAT_SEQ=$seq
  PREV_HP="" PREV_T="" RATE=0 RATES=""
  killer=$(jq -r '.killer_name // ""' <<<"$BOSS")
  me=$(jq -r '.name // ""' <<<"$ME")
  if [[ -n $killer && $killer == "$me" ]]; then
    log "*** LAST HIT! We killed boss #$seq ***"
  else
    log "Boss #$seq defeated by ${killer:-?}"
  fi
  record "$(jq -nc --argjson s "$seq" --arg k "$killer" --arg m "$me" '{t: "defeat", seq: $s, killer: $k, mine: ($k != "" and $k == $m)}')"
}

# ---------------------------------------------------------------- main

finish() {
  trap - EXIT INT TERM
  local j; j=$(jobs -p)       # an interrupted nap's sleep, the live feed helper
  [[ -n $j ]] && { kill $j; wait $j; } 2>/dev/null
  [[ -n $LIVE_FILE ]] && rm -f "$LIVE_FILE" "$LIVE_FILE.tmp"
  record '{"t":"stop"}'
  summarize "$SESSION_LOG"
  echo "Session log: $SESSION_LOG"
}
trap finish EXIT
trap 'log "stopped"; exit 0' INT TERM

record "$(jq -nc --argjson ct "$CONTENT" '{t: "start", content: $ct}')"

refresh || { log "Could not load player. Check OMHP_TOKEN."; exit 1; }
log "Playing as $(jq -r '.name // .id' <<<"$ME")  (clock skew ${SKEW}s)"
start_live
log "  $(stats)"

while true; do
  status=$(jq -r '.status // "alive"' <<<"$BOSS")
  if [[ $status != alive ]]; then
    note_defeat
    log "Boss is $status; checking again in ${DEAD_POLL}s"
    nap "$DEAD_POLL"; refresh; continue
  fi

  hoard=false; hoarding && hoard=true

  if [[ $(jq -r '.ultimate_available // false' <<<"$ME") == true ]]; then
    do_attack ultimate
  elif box=$(box_to_open); then
    do_open_box "$box"
  elif can_buy; then
    do_buy_box
  elif [[ $hoard == true ]]; then
    hoard_step
    continue
  elif (( $(jq -r '.attacks_left // 0' <<<"$ME") > 0 )); then
    do_attack normal
  else
    # Nothing to do: sleep until the next attack recharges.
    wait=$(jq -r --arg skew "$SKEW" --arg now "$(date +%s)" \
      '((.next_attack_at // 0) - ($now|tonumber) - ($skew|tonumber) + 0.5) | if . < 1 then 1 else . end' <<<"$ME")
    nap "$wait"
    refresh || nap 5
    continue
  fi
  nap "$PAUSE"
done
