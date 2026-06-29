#!/bin/sh

LOCKFILE="/tmp/dns-smart-routing.lock"
STATE_DIR="/etc/dns-smart-routing"
STATE_FILE="$STATE_DIR/state.json"
FAIL_EXPIRE_SECS=300
NOISE_WINDOW_SECS=120

# ── HYBRID SAFE LOCK ─────────────────────────────────────────────────────────
# Primary:   PID-file noclobber write
# Secondary: inode existence check
# Tertiary:  /proc/<pid>/cmdline validation
# Any ambiguity → exit gracefully (fail-safe)

_acquire_lock() {
    if [ -f "$LOCKFILE" ]; then
        local lpid
        lpid=$(cat "$LOCKFILE" 2>/dev/null)

        if [ -n "$lpid" ]; then
            if kill -0 "$lpid" 2>/dev/null; then
                # PID alive — validate via cmdline
                local cmdline
                cmdline=$(cat "/proc/$lpid/cmdline" 2>/dev/null | tr '\0' ' ')
                if echo "$cmdline" | grep -q "dns_smart_probe"; then
                    return 1  # Confirmed live — exit
                fi
                # Alive but not our process — any ambiguity → fail-safe exit
                return 1
            fi
        fi
        # PID dead or unreadable — remove stale lock
        rm -f "$LOCKFILE" 2>/dev/null
    fi

    # Atomic create via noclobber
    set -C
    ( echo "$$" > "$LOCKFILE" ) 2>/dev/null
    local rc=$?
    set +C

    # Write failure = read-only fs or inode exhaustion → exit gracefully
    [ $rc -ne 0 ] && return 1

    # Race validation: confirm our PID is what was written
    local written
    written=$(cat "$LOCKFILE" 2>/dev/null)
    [ "$written" != "$$" ] && return 1

    return 0
}

if ! _acquire_lock; then
    exit 0
fi

# Guarantee lockfile cleanup on all exit paths
trap 'rm -f "$LOCKFILE"; exit' INT TERM EXIT

mkdir -p "$STATE_DIR" 2>/dev/null || { rm -f "$LOCKFILE"; exit 0; }

# ── UCI CONFIG ───────────────────────────────────────────────────────────────
enabled=$(uci -q get dns-smart-routing.global.enabled 2>/dev/null || echo "1")
[ "$enabled" != "1" ] && exit 0

# ── STATE FILE INIT / RECOVERY ───────────────────────────────────────────────
_init_state() {
    printf '{"state":"NORMAL","fail_count":0,"ok_count":0,"last_change":0,"last_fail_time":0,"pending_state":"","pending_count":0,"last_eval_result":-1,"last_eval_time":0}\n' \
        > "$STATE_FILE" 2>/dev/null
}

if [ ! -f "$STATE_FILE" ] || [ ! -s "$STATE_FILE" ]; then
    _init_state
elif ! jq -e . "$STATE_FILE" >/dev/null 2>&1; then
    _init_state
fi

# ── DNS VALIDATION: IPv4 with bad-IP filtering (no awk) ──────────────────────
# Returns 0 if a valid, non-loopback, non-broadcast IPv4 is found in output
_dns_valid_ip() {
    local out="$1"
    local found=0
    local ip
    for ip in $(echo "$out" | grep -E -o '([0-9]{1,3}\.){3}[0-9]{1,3}'); do
        case "$ip" in
            0.0.0.0|127.*|255.255.255.255) continue ;;
            *) found=1; break ;;
        esac
    done
    return $((1 - found))
}

# DNS probe: validated by exit code AND IP presence
dns_probe_ok() {
    local resolver=$1
    local domain=$2
    local out
    out=$(nslookup "$domain" "$resolver" 2>/dev/null)
    [ $? -ne 0 ] && return 1
    _dns_valid_ip "$out"
}

# ── LATENCY: 3-run MIN (spike resistant) ─────────────────────────────────────
_uptime_ms() {
    awk '{printf "%d", $1 * 1000}' /proc/uptime 2>/dev/null || echo "0"
}

probe_min_latency() {
    local resolver=$1
    local domain=$2
    local min=99999
    local i=1
    while [ $i -le 3 ]; do
        local t0 t1 lat
        t0=$(_uptime_ms)
        if dns_probe_ok "$resolver" "$domain"; then
            t1=$(_uptime_ms)
            lat=$((t1 - t0))
            [ $lat -lt $min ] && min=$lat
        else
            echo "-1"
            return
        fi
        i=$((i + 1))
    done
    echo "$min"
}

# ── EVALUATION LOOP ───────────────────────────────────────────────────────────
DOMAINS="google.com cloudflare.com"
RESOLVERS="1.1.1.1 8.8.8.8"
failed=0

for domain in $DOMAINS; do
    domain_ok=0
    for resolver in $RESOLVERS; do
        lat=$(probe_min_latency "$resolver" "$domain")
        if [ "$lat" != "-1" ] && [ "$lat" -le 400 ] 2>/dev/null; then
            domain_ok=1
            break
        fi
    done
    if [ $domain_ok -eq 0 ]; then
        failed=1
        break
    fi
done

# ── READ CURRENT STATE (safe fallbacks on every field) ───────────────────────
now=$(date +%s 2>/dev/null || echo "0")

current_state=$(jq -r    '.state           // "NORMAL"' "$STATE_FILE" 2>/dev/null || echo "NORMAL")
fail_count=$(jq -r        '.fail_count      // 0'        "$STATE_FILE" 2>/dev/null || echo "0")
ok_count=$(jq -r          '.ok_count        // 0'        "$STATE_FILE" 2>/dev/null || echo "0")
last_change=$(jq -r       '.last_change     // 0'        "$STATE_FILE" 2>/dev/null || echo "0")
last_fail_time=$(jq -r    '.last_fail_time  // 0'        "$STATE_FILE" 2>/dev/null || echo "0")
pending_state=$(jq -r     '.pending_state   // ""'        "$STATE_FILE" 2>/dev/null || echo "")
pending_count=$(jq -r     '.pending_count   // 0'         "$STATE_FILE" 2>/dev/null || echo "0")
last_eval_result=$(jq -r  '.last_eval_result // -1'       "$STATE_FILE" 2>/dev/null || echo "-1")
last_eval_time=$(jq -r    '.last_eval_time  // 0'         "$STATE_FILE" 2>/dev/null || echo "0")

# Sanitize all integers
fail_count=$(printf '%d'       "$fail_count"       2>/dev/null || echo "0")
ok_count=$(printf '%d'         "$ok_count"         2>/dev/null || echo "0")
last_change=$(printf '%d'      "$last_change"      2>/dev/null || echo "0")
last_fail_time=$(printf '%d'   "$last_fail_time"   2>/dev/null || echo "0")
pending_count=$(printf '%d'    "$pending_count"    2>/dev/null || echo "0")
last_eval_result=$(printf '%d' "$last_eval_result" 2>/dev/null || echo "-1")
last_eval_time=$(printf '%d'   "$last_eval_time"   2>/dev/null || echo "0")

# ── NOISE FILTER: 2 consecutive identical results within NOISE_WINDOW_SECS ───
# Result is "confirmed" only if previous eval had same value within time window
eval_confirmed=0
if [ "$last_eval_result" -eq "$failed" ] 2>/dev/null; then
    time_since=$((now - last_eval_time))
    if [ $time_since -le $NOISE_WINDOW_SECS ] && [ $time_since -ge 0 ]; then
        eval_confirmed=1
    fi
fi

# Always record this evaluation
last_eval_result=$failed
last_eval_time=$now

# If not confirmed — persist eval fields only and exit safely
if [ $eval_confirmed -eq 0 ]; then
    TMP_STATE="${STATE_FILE}.tmp"
    jq -n \
        --arg  st  "$current_state" \
        --argjson fc "$fail_count" \
        --argjson oc "$ok_count" \
        --argjson lc "$last_change" \
        --argjson lf "$last_fail_time" \
        --arg  ps  "$pending_state" \
        --argjson pc "$pending_count" \
        --argjson er "$last_eval_result" \
        --argjson et "$last_eval_time" \
        '{state:$st,fail_count:$fc,ok_count:$oc,last_change:$lc,last_fail_time:$lf,pending_state:$ps,pending_count:$pc,last_eval_result:$er,last_eval_time:$et}' \
        > "$TMP_STATE" 2>/dev/null && mv "$TMP_STATE" "$STATE_FILE" 2>/dev/null
    exit 0
fi

# ── CONFIRMED — UPDATE COUNTERS ───────────────────────────────────────────────
if [ $failed -eq 1 ]; then
    fail_count=$((fail_count + 1))
    ok_count=0
    last_fail_time=$now
else
    ok_count=$((ok_count + 1))
    fail_count=0
fi

# ── TIME DECAY: expire stale failures ─────────────────────────────────────────
if [ $failed -eq 0 ] && [ $fail_count -gt 0 ] && [ $last_fail_time -gt 0 ]; then
    age=$((now - last_fail_time))
    [ $age -ge $FAIL_EXPIRE_SECS ] && fail_count=0
fi

# ── RAW DESIRED STATE ─────────────────────────────────────────────────────────
desired_state="$current_state"
[ $fail_count -ge 4 ] && [ "$current_state" != "FAILOVER" ] && desired_state="FAILOVER"
[ $ok_count   -ge 8 ] && [ "$current_state" != "NORMAL"   ] && desired_state="NORMAL"

# ── HYSTERESIS: 2 evaluation windows before committing ───────────────────────
new_state="$current_state"

if [ "$desired_state" != "$current_state" ]; then
    if [ "$pending_state" = "$desired_state" ]; then
        pending_count=$((pending_count + 1))
    else
        pending_state="$desired_state"
        pending_count=1
    fi

    if [ $pending_count -ge 2 ]; then
        elapsed=$((now - last_change))
        if [ $elapsed -ge 120 ]; then
            new_state="$desired_state"
            last_change=$now
            pending_state=""
            pending_count=0
        fi
    fi
else
    pending_state=""
    pending_count=0
fi

# ── ATOMIC STATE WRITE (filesystem safety mode) ───────────────────────────────
# On any write failure: skip silently (current state preserved on disk)
TMP_STATE="${STATE_FILE}.tmp"
jq -n \
    --arg  st  "$new_state" \
    --argjson fc "$fail_count" \
    --argjson oc "$ok_count" \
    --argjson lc "$last_change" \
    --argjson lf "$last_fail_time" \
    --arg  ps  "$pending_state" \
    --argjson pc "$pending_count" \
    --argjson er "$last_eval_result" \
    --argjson et "$last_eval_time" \
    '{state:$st,fail_count:$fc,ok_count:$oc,last_change:$lc,last_fail_time:$lf,pending_state:$ps,pending_count:$pc,last_eval_result:$er,last_eval_time:$et}' \
    > "$TMP_STATE" 2>/dev/null || exit 0

mv "$TMP_STATE" "$STATE_FILE" 2>/dev/null || {
    rm -f "$TMP_STATE" 2>/dev/null
    exit 0
}
