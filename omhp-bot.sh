#!/usr/bin/env bash
# Auto-player for https://onemillionhp.com
#
# Loop, driven by the `me` object every API response returns:
#   1. ultimate ready     -> use it
#      ultimate recharging -> hold normal attacks (except at the attack cap),
#                             then spend them all right after the ultimate
#      scroll owned        -> use it (scrolls replaced the ultimate)
#   2. loot box in bag    -> open it
#   3. enough shards      -> buy a box (default: occult ossuary), opened by step 2
# Every optional step (ultimate, scroll, box, buy) that errors is disabled for
# a while and the pass falls through to a normal attack.
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
BUY_BOX="${OMHP_BUY_BOX-occult_ossuary}" # box to buy with shards; empty disables buying
ULT_HOLD="${OMHP_ULT_HOLD:-1}"    # 1 = hold attacks while the ultimate recharges, spend them right after
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
        "Scrolls used    \(map(select(.t == "scroll")) | if length == 0 then "none" else (group_by(.scroll_id) | map("\(.[0].scroll_id) x\(length)") | join(", ")) end)",
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
  out=${out%$'\n'*}
  # A non-JSON body (proxy error page, changed endpoint) becomes a JSON error
  # carrying the HTTP status, so callers can always parse what they get.
  if ! jq -e . <<<"$out" >/dev/null 2>&1; then
    printf '{"error":{"code":"HTTP_%s","message":"non-JSON response"}}' "$code"
    return 1
  fi
  printf '%s' "$out"
  [[ $code == 2* ]]
}

rid() { uuidgen | tr 'A-Z' 'a-z'; }

# Server clock offset, so we sleep exactly until next_attack_at.
server_now() {
  api GET /api/state | jq -r '.server_time // empty'
}
# (sub-second local time: `date +%s` truncates, which made the server look up
# to 1s ahead and the ultimate get fired early)
SKEW=$(jq -rn --arg s "$(server_now)" 'if ($s | length) > 0 then ($s | tonumber) - now | . * 1000 | round / 1000 else 0 end' 2>/dev/null)
[[ $SKEW =~ ^-?[0-9.]+$ ]] || SKEW=0

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

error_code() { jq -r '.error.code // "UNKNOWN"' <<<"$1" 2>/dev/null || echo UNKNOWN; }

# handle_error WHAT RESPONSE [optional]: optional actions never wait here, so
# the pass moves straight on to a normal attack.
handle_error() {
  local what=$1 res=$2 optional=${3:-} code
  code=$(error_code "$res")
  LAST_ERROR=$code
  log "$what failed: $code $(jq -r '.error.message // empty' <<<"$res" 2>/dev/null)"
  case $code in
    NEED_NAME) log "Pick a name in the web UI first."; exit 1 ;;
    HTTP_401|UNAUTHORIZED|UNAUTHENTICATED) log "Token rejected."; exit 1 ;;
    NETWORK|HTTP_429|HTTP_5*) [[ -n $optional ]] || nap 3 ;;
  esac
  refresh || [[ -n $optional ]] || nap 3
}

# ---- resilience: optional actions (ultimate, scroll, box, buy) back
# off after an error and the pass falls through to a normal attack, so a game
# change can cost at most one attempt per backoff, never all our attacks.
ACTION_BLOCKED="" # "name:until ..."
SPAM=false        # true right after an ultimate: spend every held attack
LAST_ERROR=""     # error code of the last failed request

action_ok() { # NAME
  local until
  until=$(printf '%s\n' $ACTION_BLOCKED | awk -F: -v n="$1" '$1 == n { u = $2 } END { print u + 0 }')
  (( $(date +%s) >= until ))
}

block_action() { # NAME SECONDS [REASON]
  ACTION_BLOCKED="$(printf '%s\n' $ACTION_BLOCKED | awk -F: -v n="$1" '$1 != n' | tr '\n' ' ')$1:$(( $(date +%s) + $2 ))"
  log "$1 disabled for ${2}s after an error${3:+ ($3)}; attacking normally meanwhile"
}

# take_me JSON: adopt a response's `me` if it has one, otherwise re-fetch
take_me() {
  local m
  m=$(jq -c '.me // empty | select(type == "object")' <<<"$1" 2>/dev/null)
  if [[ -n $m ]]; then ME=$m; else refresh; fi
}

# A number from ME, or DEFAULT if the field is missing or not a number.
me_num() { # FIELD DEFAULT
  jq -r --arg f "$1" --arg d "$2" '.[$f] | if type == "number" then . else $d end' <<<"$ME" 2>/dev/null || echo "$2"
}

stats() {
  jq -r '"attacks \(.attacks_left)/\(.attacks_per_day)  boss dmg \(.boss_damage // 0)  boxes \([(.boxes // [])[] | .count // 1] | add // 0)  crits \(.next_crits // 0)  scrolls \([(.scrolls // [])[] | .count // 1] | add // 0)  shards \(.shards // 0)  ult \(if .ultimate_available then "READY" elif .ultimate_used then "spent" else "-" end)"' <<<"$ME"
}

# ---------------------------------------------------------------- actions

attack_body() { jq -nc --arg k "$1" --arg r "$(rid)" '{kind:$k, request_id:$r}'; }

# The ultimate recharges on a timer (me.ultimate_ready_at, every
# me.ult_recharge = 60s, restarting when it's used), and a normal attack can
# refund a spent one. A refused ultimate is retried after a backoff that starts
# at 5s (a timing refusal) and doubles up to ULT_BACKOFF on repeated refusals
# (the game once removed the ultimate outright while still reporting it ready).
ULT_BACKOFF="${OMHP_ULT_BACKOFF:-600}"
ULT_FAILS=0

# ult_wait: seconds until the ultimate is ready (server clock), or nothing if
# the server doesn't report a timer.
ult_wait() {
  jq -r --argjson skew "$SKEW" 'if (.ultimate_ready_at | type) == "number"
    then (.ultimate_ready_at - (now + $skew) | . * 100 | round / 100) else empty end' <<<"$ME" 2>/dev/null
}

ult_ready() {
  local w; w=$(ult_wait)
  if [[ -n $w ]]; then awk -v w="$w" 'BEGIN { exit !(w <= 0) }'
  else [[ $(jq -r '.ultimate_available // false' <<<"$ME" 2>/dev/null) == true ]]; fi
}

ult_backoff() { # seconds to wait after the Nth refusal in a row
  awk -v n="$ULT_FAILS" -v max="$ULT_BACKOFF" 'BEGIN { s = 5 * 2 ^ (n - 1); print (s > max ? max : s) }'
}

do_attack() { # kind = normal | ultimate; returns 1 if the server refused it
  local kind=$1 res
  if res=$(api POST /api/attack "$(attack_body "$kind")"); then
    on_attack "$kind" "$res"
  else
    handle_error "attack($kind)" "$res" $([[ $kind == ultimate ]] && echo optional)
    return 1
  fi
}

# on_attack KIND RESPONSE [quiet]: take the new state, log and record the hit
on_attack() {
  local kind=$1 res=$2 quiet=${3:-}
  take_me "$res"
  local b; b=$(jq -c '.boss // empty | select(type == "object")' <<<"$res" 2>/dev/null)
  [[ -n $b ]] && BOSS=$b
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
  take_me "$2"
  record "$(jq -c --arg b "$1" --argjson ct "$CONTENT" '.result as $r | ($ct.items // {})[$r.item_id // ""] as $i |
    {t: "box", box_id: $b, result: ($r + {item_name: $i.name, rarity: ($r.rarity // $i.rarity)})}' <<<"$2")"
}

do_open_box() {
  local box=$1 res
  if res=$(api POST /api/boxes/open "$(open_body "$box")"); then
    on_box_open "$box" "$res"
    log "OPENED $box -> $(jq -c '.result' <<<"$res")"
  else
    handle_error "open($box)" "$res" optional
    return 1
  fi
}

# ---- scrolls (drop from attacks; used as soon as we have one)

SCROLL_BLOCKED="" # "id:until ..." for scrolls the server refused, retried after 120s

scroll_to_use() {
  jq -er --arg blocked "$SCROLL_BLOCKED" --argjson now "$(date +%s)" '
    ($blocked | split(" ") | map(select(. != "") | split(":") | {key: .[0], value: (.[1] | tonumber)}) | from_entries) as $b
    | [(.scrolls // [])[] | select((.count // 1) > 0 and (($b[.scroll_id] // 0) <= $now)) | .scroll_id][0] // empty' <<<"$ME"
}

do_use_scroll() {
  local id=$1 res
  if res=$(api POST /api/scrolls/use "$(jq -nc --arg s "$id" '{scroll_id: $s}')"); then
    take_me "$res"
    local b; b=$(jq -c '.boss // empty | select(type == "object")' <<<"$res" 2>/dev/null); [[ -n $b ]] && BOSS=$b
    record "$(jq -c --arg s "$id" '{t: "scroll", scroll_id: $s, amount: .amount, shards: .shards}' <<<"$res")"
    log "SCROLL: used $id$(jq -r 'if .amount then " (amount \(.amount))" else "" end + if .shards then " +\(.shards) shards" else "" end' <<<"$res")"
  else
    SCROLL_BLOCKED="$SCROLL_BLOCKED $id:$(( $(date +%s) + 120 ))"
    log "scroll $id refused ($(error_code "$res")): $(jq -r '.error.message // empty' <<<"$res"); retrying in 120s"
    refresh
    return 1
  fi
}

# Price of BUY_BOX: me.shop has the admin's price changes applied; the
# fallback is the shop list at the time of writing.
box_price() {
  jq -r --arg b "$BUY_BOX" '.shop.boxes[$b] // ({wooden_crate: 10, iron_chest: 30, cursed_casket: 100, occult_ossuary: 500}[$b]) // 100' <<<"$ME"
}

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
    take_me "$res"
    BUY_BLOCKED_AT=""
    record "$(jq -nc --arg b "$BUY_BOX" --argjson p "$price" '{t: "buy", box_id: $b, price: $p}')"
    log "BOUGHT $BUY_BOX for $price shards  ($(jq -r '.shards // 0' <<<"$ME") left)"
  else
    BUY_BLOCKED_AT=$shards
    handle_error "buy($BUY_BOX)" "$res" optional
    return 1
  fi
}

# box_to_open: the first box in the bag, if any.
box_to_open() { jq -er '[(.boxes // [])[] | select((.count // 1) > 0) | .box_id][0] // empty' <<<"$ME" 2>/dev/null; }

# ---------------------------------------------------------------- boss kills

# Record each boss defeat once, noting whether we landed the killing blow.
LAST_DEFEAT_SEQ=""
note_defeat() {
  local seq killer me
  seq=$(jq -r '.seq // ""' <<<"$BOSS")
  [[ -z $seq || $seq == "$LAST_DEFEAT_SEQ" ]] && return
  LAST_DEFEAT_SEQ=$seq
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
  local j; j=$(jobs -p)       # an interrupted nap's sleep
  [[ -n $j ]] && { kill $j; wait $j; } 2>/dev/null
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
    note_defeat
    log "Boss is $status; checking again in ${DEAD_POLL}s"
    nap "$DEAD_POLL"; refresh; continue
  fi

  # Optional actions first. Each one that errors is disabled for a while
  # and the pass carries on, so the normal attack below always gets its turn.
  if action_ok ult && ult_ready; then
    if do_attack ultimate; then ULT_FAILS=0 SPAM=true; nap "$PAUSE"; continue; fi
    ULT_FAILS=$((ULT_FAILS + 1))
    block_action ult "$(ult_backoff)" "ultimate refused, $ULT_FAILS in a row"
  fi
  if action_ok scroll && scroll=$(scroll_to_use); then
    if do_use_scroll "$scroll"; then nap "$PAUSE"; continue; fi
  fi
  if action_ok box && box=$(box_to_open); then
    if do_open_box "$box"; then nap "$PAUSE"; continue; fi
    block_action box 120 "opening $box"
  fi
  if action_ok buy && can_buy; then
    if do_buy_box; then nap "$PAUSE"; continue; fi
    block_action buy 300 "buying $BUY_BOX"
  fi

  left=$(me_num attacks_left -1)
  uwait=$(ult_wait)

  # Ultimate cycle: a refund proc restarts the 60s timer, so a refund right
  # after an ultimate is worth a whole extra one, while one late in the cycle
  # only moves it up a few seconds. So hold normal attacks while the ultimate
  # recharges and spend them all right after it. Never hold at the attack cap
  # (recharge would be wasted), and only while the ultimate is working.
  if [[ $ULT_HOLD == 1 && $SPAM == false && -n $uwait ]] && action_ok ult \
     && (( left < $(me_num attacks_per_day 20) )); then
    if [[ ${HOLD_LOGGED:-} != "$(jq -r '.ultimate_ready_at' <<<"$ME")" ]]; then
      log "holding attacks for the ultimate (ready in ${uwait}s, $left held)"
      HOLD_LOGGED=$(jq -r '.ultimate_ready_at' <<<"$ME")
    fi
    # Sleep to whichever comes first: the ultimate, or the next attack.
    wait=$(jq -rn --argjson u "$uwait" --argjson a "$(jq -r --argjson skew "$SKEW" \
      'if (.next_attack_at | type) == "number" then .next_attack_at - (now + $skew) else 5 end' <<<"$ME" 2>/dev/null || echo 5)" \
      '[$u + 0.3, $a + 0.3] | min | if . < 0.2 then 0.2 elif . > 60 then 60 else . end' 2>/dev/null)
    nap "${wait:-1}"
    refresh || nap 5
    continue
  fi

  # The default: a normal attack. If attacks_left is missing or renamed,
  # try anyway and let the server say NO_ATTACKS.
  if (( left != 0 )); then
    # Out of attacks (the server says so even when attacks_left is missing):
    # wait a recharge interval rather than asking again every second.
    do_attack normal || { [[ $LAST_ERROR == NO_ATTACKS ]] && { SPAM=false; nap "$(me_num recharge_seconds 5)"; } || nap 1; }
  else
    SPAM=false # all attacks spent
    # Nothing to do: sleep until the next attack recharges (next_attack_at,
    # or the recharge interval if that field is missing), or until the
    # ultimate is ready if that comes first.
    wait=$(jq -r --arg skew "$SKEW" --arg now "$(date +%s)" --arg u "${uwait:-}" '
      (if (.next_attack_at | type) == "number"
       then (.next_attack_at - ($now|tonumber) - ($skew|tonumber) + 0.5)
       else (.recharge_seconds // 5) end) as $a
      | (if $u != "" then [$a, ($u | tonumber) + 0.3] | min else $a end)
      | if . < 0.2 then 0.2 elif . > 60 then 60 else . end' <<<"$ME" 2>/dev/null)
    nap "${wait:-5}"
    refresh || nap 5
    continue
  fi
  nap "$PAUSE"
done
