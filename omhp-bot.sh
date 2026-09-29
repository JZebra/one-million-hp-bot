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
# Usage:
#   OMHP_TOKEN=xxxx ./omhp-bot.sh
# Get the token from the game tab's devtools console:
#   localStorage.getItem("omhp.token")
#
# Requires: curl, jq, uuidgen (all stock on macOS except jq: brew install jq)

set -uo pipefail

API="${OMHP_API:-https://onemillionhp.com}"
TOKEN="${OMHP_TOKEN:?set OMHP_TOKEN (localStorage.getItem(\"omhp.token\") in the game tab)}"
PAUSE="${OMHP_PAUSE:-0.4}"        # seconds between consecutive actions
DEAD_POLL="${OMHP_DEAD_POLL:-30}" # seconds between checks while no boss is alive
BUY_BOX="${OMHP_BUY_BOX-cursed_casket}" # box to buy with shards; empty disables buying

log() { printf '%s  %s\n' "$(date +%H:%M:%S)" "$*"; }

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
    NETWORK|HTTP_429|HTTP_5*) sleep 5 ;;
  esac
  refresh || sleep 5
}

stats() {
  jq -r '"attacks \(.attacks_left)/\(.attacks_per_day)  boss dmg \(.boss_damage // 0)  boxes \((.boxes // []) | length)  shards \(.shards // 0)  ult \(if .ultimate_available then "READY" elif .ultimate_used then "spent" else "-" end)"' <<<"$ME"
}

do_attack() { # kind = normal | ultimate
  local kind=$1 res
  if res=$(api POST /api/attack "$(jq -nc --arg k "$kind" --arg r "$(rid)" '{kind:$k, request_id:$r}')"); then
    ME=$(jq -c '.me' <<<"$res")
    BOSS=$(jq -c '.boss // {}' <<<"$res")
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
  local res shards
  shards=$(jq -r '.shards // 0' <<<"$ME")
  if res=$(api POST /api/shop/buy "$(jq -nc --arg b "$BUY_BOX" '{box_id:$b}')"); then
    ME=$(jq -c '.me' <<<"$res")
    BUY_BLOCKED_AT=""
    log "BOUGHT $BUY_BOX for $(box_price) shards  ($(jq -r '.shards // 0' <<<"$ME") left)"
  else
    BUY_BLOCKED_AT=$shards
    handle_error "buy($BUY_BOX)" "$res"
  fi
}

trap 'log "stopped"; exit 0' INT TERM

refresh || { log "Could not load player. Check OMHP_TOKEN."; exit 1; }
log "Playing as $(jq -r '.name // .id' <<<"$ME")  (clock skew ${SKEW}s)"
log "  $(stats)"

while true; do
  status=$(jq -r '.status // "alive"' <<<"$BOSS")
  if [[ $status != alive ]]; then
    log "Boss is $status; checking again in ${DEAD_POLL}s"
    sleep "$DEAD_POLL"; refresh; continue
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
    sleep "$wait"
    refresh || sleep 5
    continue
  fi
  sleep "$PAUSE"
done
