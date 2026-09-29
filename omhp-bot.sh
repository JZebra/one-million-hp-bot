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
LOG_DIR="${OMHP_LOG_DIR:-$(cd "$(dirname "$0")" && pwd)/logs}"

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
    | $start.content as $ct
    | [
        "",
        "=============== SESSION SUMMARY ===============",
        "Duration        \(($end - ($start.ts // $end)) | dur)",
        "Attacks         \($atk | length | c)   (normal \($norm | length | c), crit \($crit | length | c), ultimate \($ult | length | c))",
        "Total damage    \($atk | map(.damage) | add // 0 | c)",
        "Avg damage      normal \($norm | avg)   crit \($crit | avg)   ultimate \($ult | avg)",
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
  rarity_rank: ([.rarities[]? | {key: .id, value: .rank}] | from_entries)
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
  jq -r '"attacks \(.attacks_left)/\(.attacks_per_day)  boss dmg \(.boss_damage // 0)  boxes \((.boxes // []) | length)  shards \(.shards // 0)  ult \(if .ultimate_available then "READY" elif .ultimate_used then "spent" else "-" end)"' <<<"$ME"
}

# ---------------------------------------------------------------- actions

do_attack() { # kind = normal | ultimate
  local kind=$1 res
  if res=$(api POST /api/attack "$(jq -nc --arg k "$kind" --arg r "$(rid)" '{kind:$k, request_id:$r}')"); then
    ME=$(jq -c '.me' <<<"$res")
    BOSS=$(jq -c '.boss // {}' <<<"$res")
    record "$(jq -c --arg k "$kind" '.attack as $a | {t: "attack", kind: $k, damage: ($a.damage // 0),
      crit: ($a.crit // false), item_id: $a.item_id, procs: ($a.procs // {}), boss_seq: .boss.seq}' <<<"$res")"
    jq -r --arg k "$kind" '.attack as $a | "\($k | ascii_upcase): \($a.damage) dmg" +
        (if $a.crit then " CRIT" else "" end) +
        (if $a.item_id then "  +item \($a.item_id)" else "" end) +
        (if ($a.procs.box_id // null) then "  +box \($a.procs.box_id)" else "" end) +
        (($a.procs // {}) | to_entries | map(select(.key != "box_id" and .value)) | map("  [" + .key + "]") | join(""))' <<<"$res" |
      while read -r line; do log "$line"; done
    log "  $(stats)"
  else
    handle_error "attack($kind)" "$res"
  fi
}

do_open_box() {
  local box=$1 res
  if res=$(api POST /api/boxes/open "$(jq -nc --arg b "$box" --arg r "$(rid)" '{box_id:$b, request_id:$r}')"); then
    ME=$(jq -c '.me' <<<"$res")
    record "$(jq -c --arg b "$box" --argjson ct "$CONTENT" '.result as $r | ($ct.items // {})[$r.item_id // ""] as $i |
      {t: "box", box_id: $b, result: ($r + {item_name: $i.name, rarity: ($r.rarity // $i.rarity)})}' <<<"$res")"
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

# ---------------------------------------------------------------- main

finish() {
  trap - EXIT INT TERM
  kill $(jobs -p) 2>/dev/null # an interrupted nap's sleep
  record '{"t":"stop"}'
  summarize "$SESSION_LOG"
  echo "Session log: $SESSION_LOG"
}
trap finish EXIT
trap 'log "stopped"; exit 0' INT TERM

record "$(jq -nc --argjson ct "$CONTENT" '{t: "start", content: $ct}')"

refresh || { log "Could not load player. Check OMHP_TOKEN."; exit 1; }
log "Playing as $(jq -r '.name // .id' <<<"$ME")  (clock skew ${SKEW}s)"
log "  $(stats)"

while true; do
  status=$(jq -r '.status // "alive"' <<<"$BOSS")
  if [[ $status != alive ]]; then
    log "Boss is $status; checking again in ${DEAD_POLL}s"
    nap "$DEAD_POLL"; refresh; continue
  fi

  if [[ $(jq -r '.ultimate_available // false' <<<"$ME") == true ]]; then
    do_attack ultimate
  elif box=$(jq -er '(.boxes // [])[0].box_id' <<<"$ME"); then
    do_open_box "$box"
  elif can_buy; then
    do_buy_box
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
