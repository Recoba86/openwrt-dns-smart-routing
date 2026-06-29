#!/bin/sh

LOCKFILE="/tmp/dns-smart-routing.lock"
STATE_DIR="/etc/dns-smart-routing"
STATE_FILE="$STATE_DIR/state.json"
FAIL_EXPIRE_SECS=300

# ── ATOMIC PID-FILE LOCK ─────────────────────────────────────────────────────
# Uses noclobber for atomic create; falls back to dead-PID removal + retry.
_acquire_lock() {
    # Attempt 1: atomic create via noclobber
    set -C
    ( echo "$$" > "$LOCKFILE" ) 2>/dev/null
    local rc=$?
    set +C
    [ $rc -eq 0 ] && return 0

    # File exists — check if owning PID is alive
    local lpid
    lpid=$(cat "$LOCKFILE" 2>/dev/null)
    if [ -n "$lpid" ] && kill -0 "$lpid" 2>/dev/null; then
        return 1  # Owner alive — exit
    fi

    # Owner dead — remove stale lock and retry once
    rm -f "$LOCKFILE"
    set -C
    ( echo "$$" > "$LOCKFILE" ) 2>/dev/null
    rc=$?
    set +C
    return $rc
}

if ! _acquire_lock; then
    exit 0
fi

# Guarantee cleanup on any exit path
trap 'rm -f "$LOCKFILE"; exit' INT TERM EXIT

mkdir -p "$STATE_DIR"

# ── UCI CONFIG ───────────────────────────────────────────────────────────────
enabled=$(uci -q get dns-smart-routing.global.enabled 2>/dev/null || echo "1")
[ "$enabled" != "1" ] && exit 0

# ── STATE FILE INIT / RECOVERY ───────────────────────────────────────────────
_init_state() {
    printf '{"state":"NORMAL","fail_count":0,"ok_count":0,"last_change":0,"last_fail_time":0,"pending_state":"","pending_count":0}\n' \
        > "$STATE_FILE"
}

if [ ! -f "$STATE_FILE" ] || [ ! -s "$STATE_FILE" ]; then
    _init_state
elif ! jq -e . "$STATE_FILE" >/dev/null 2>&1; then
    _init_state
fi

# ── DNS PROBE: exit code + IPv4 validation (no awk) ─────────────────────────
# Returns 0 (success with valid IP) or 1 (failure/no IP/timeout)
_dns_has_ip() {
    # Check output for any IPv4 address pattern using grep only
    echo "$1" | grep -E -o '([0-9]{1,3}\.){3}[0-9]{1,3}' | grep -v '^0\.' | grep -q '.'
}

dns_probe() {
    local resolver=$1
    local domain=$2
    local out
    out=$(nslookup "$domain" "$resolver" 2>/dev/null)
    local rc=$?
    [ $rc -ne 0 ] && echo "-1" && return
    if ! _dns_has_ip "$out"; then
        echo "-1"
        return
    fi
    echo "0"  # success (IP confirmed present)
}

# ── LATENCY: 3-run minimum (avoids false failover from CPU spikes) ───────────
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
        local result
        result=$(dns_probe "$resolver" "$domain")
        t1=$(_uptime_ms)
        if [ "$result" = "-1" ]; then
            echo "-1"
            return
        fi
        lat=$((t1 - t0))
        [ $lat -lt $min ] && min=$lat
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

current_state=$(jq -r   '.state         // "NORMAL"' "$STATE_FILE" 2>/dev/null || echo "NORMAL")
fail_count=$(jq -r       '.fail_count    // 0'        "$STATE_FILE" 2>/dev/null || echo "0")
ok_count=$(jq -r         '.ok_count      // 0'        "$STATE_FILE" 2>/dev/null || echo "0")
last_change=$(jq -r      '.last_change   // 0'        "$STATE_FILE" 2>/dev/null || echo "0")
last_fail_time=$(jq -r   '.last_fail_time// 0'        "$STATE_FILE" 2>/dev/null || echo "0")
pending_state=$(jq -r    '.pending_state // ""'        "$STATE_FILE" 2>/dev/null || echo "")
pending_count=$(jq -r    '.pending_count // 0'         "$STATE_FILE" 2>/dev/null || echo "0")

# Sanitize integers
fail_count=$(printf '%d'    "$fail_count"    2>/dev/null || echo "0")
ok_count=$(printf '%d'      "$ok_count"      2>/dev/null || echo "0")
last_change=$(printf '%d'   "$last_change"   2>/dev/null || echo "0")
last_fail_time=$(printf '%d' "$last_fail_time" 2>/dev/null || echo "0")
pending_count=$(printf '%d' "$pending_count" 2>/dev/null || echo "0")

# ── TIME DECAY: expire stale failures after FAIL_EXPIRE_SECS ─────────────────
if [ $failed -eq 0 ] && [ $fail_count -gt 0 ] && [ $last_fail_time -gt 0 ]; then
    age=$((now - last_fail_time))
    [ $age -ge $FAIL_EXPIRE_SECS ] && fail_count=0
fi

# ── UPDATE COUNTERS ───────────────────────────────────────────────────────────
if [ $failed -eq 1 ]; then
    fail_count=$((fail_count + 1))
    ok_count=0
    last_fail_time=$now
else
    ok_count=$((ok_count + 1))
    fail_count=0
fi

# ── RAW DESIRED STATE ─────────────────────────────────────────────────────────
desired_state="$current_state"
[ $fail_count -ge 4 ] && [ "$current_state" != "FAILOVER" ] && desired_state="FAILOVER"
[ $ok_count   -ge 8 ] && [ "$current_state" != "NORMAL"   ] && desired_state="NORMAL"

# ── HYSTERESIS: require 2 consecutive windows before committing change ────────
new_state="$current_state"

if [ "$desired_state" != "$current_state" ]; then
    if [ "$pending_state" = "$desired_state" ]; then
        pending_count=$((pending_count + 1))
    else
        pending_state="$desired_state"
        pending_count=1
    fi

    if [ $pending_count -ge 2 ]; then
        # Enforce cooldown (120s minimum between changes)
        elapsed=$((now - last_change))
        if [ $elapsed -ge 120 ]; then
            new_state="$desired_state"
            last_change=$now
            pending_state=""
            pending_count=0
        fi
    fi
else
    # No desired change — reset pending
    pending_state=""
    pending_count=0
fi

# ── ATOMIC STATE WRITE ────────────────────────────────────────────────────────
TMP_STATE="${STATE_FILE}.tmp"
jq -n \
    --arg  st  "$new_state" \
    --argjson fc "$fail_count" \
    --argjson oc "$ok_count" \
    --argjson lc "$last_change" \
    --argjson lf "$last_fail_time" \
    --arg  ps  "$pending_state" \
    --argjson pc "$pending_count" \
    '{state:$st,fail_count:$fc,ok_count:$oc,last_change:$lc,last_fail_time:$lf,pending_state:$ps,pending_count:$pc}' \
    > "$TMP_STATE" 2>/dev/null && mv "$TMP_STATE" "$STATE_FILE"
