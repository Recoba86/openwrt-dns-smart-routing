#!/bin/sh

LOCKDIR="/tmp/dns-smart-routing.lock"
STATE_DIR="/etc/dns-smart-routing"
STATE_FILE="$STATE_DIR/state.json"
FAIL_EXPIRE_SECS=300

# ── ATOMIC MKDIR LOCK ────────────────────────────────────────────────────────
acquire_lock() {
    if mkdir "$LOCKDIR" 2>/dev/null; then
        echo "$$" > "$LOCKDIR/pid"
        return 0
    fi
    # Lock dir exists — check if owning PID is still alive
    lock_pid=$(cat "$LOCKDIR/pid" 2>/dev/null)
    if [ -n "$lock_pid" ] && ! kill -0 "$lock_pid" 2>/dev/null; then
        # Owning process is dead — remove stale lock
        rm -rf "$LOCKDIR"
        if mkdir "$LOCKDIR" 2>/dev/null; then
            echo "$$" > "$LOCKDIR/pid"
            return 0
        fi
    fi
    return 1
}

if ! acquire_lock; then
    exit 0
fi

# Ensure lock is always removed on exit (including normal, signal, crash)
trap 'rm -rf "$LOCKDIR"; exit' INT TERM EXIT

mkdir -p "$STATE_DIR"

# ── UCI CONFIG ───────────────────────────────────────────────────────────────
enabled=$(uci -q get dns-smart-routing.global.enabled 2>/dev/null || echo "1")
[ "$enabled" != "1" ] && exit 0

# ── STATE FILE INIT / RECOVERY ───────────────────────────────────────────────
safe_init_state() {
    printf '{"state":"NORMAL","fail_count":0,"ok_count":0,"last_change":0,"last_fail_time":0}\n' \
        > "$STATE_FILE"
}

if [ ! -f "$STATE_FILE" ] || [ ! -s "$STATE_FILE" ]; then
    safe_init_state
elif ! jq -e . "$STATE_FILE" >/dev/null 2>&1; then
    safe_init_state
fi

# ── DNS PROBE (exit-code only, no awk parsing) ───────────────────────────────
# Returns 0 (success) or 1 (failure/timeout)
dns_ok() {
    resolver=$1
    domain=$2
    nslookup "$domain" "$resolver" >/dev/null 2>&1
    return $?
}

# Measure latency via /proc/uptime (BusyBox safe)
uptime_ms() {
    awk '{printf "%d", $1 * 1000}' /proc/uptime 2>/dev/null || echo "0"
}

probe_resolver() {
    resolver=$1
    domain=$2
    t0=$(uptime_ms)
    if dns_ok "$resolver" "$domain"; then
        t1=$(uptime_ms)
        echo $((t1 - t0))
    else
        echo "-1"
    fi
}

DOMAINS="google.com cloudflare.com"
RESOLVERS="1.1.1.1 8.8.8.8"
failed=0

for domain in $DOMAINS; do
    domain_ok=0
    for resolver in $RESOLVERS; do
        latency=$(probe_resolver "$resolver" "$domain")
        if [ "$latency" -ge 0 ] 2>/dev/null && [ "$latency" -le 300 ] 2>/dev/null; then
            domain_ok=1
            break
        fi
    done
    if [ $domain_ok -eq 0 ]; then
        failed=1
        break
    fi
done

# ── READ CURRENT STATE (with safe fallbacks) ─────────────────────────────────
now=$(date +%s 2>/dev/null || echo "0")

current_state=$(jq -r '.state // "NORMAL"'        "$STATE_FILE" 2>/dev/null || echo "NORMAL")
fail_count=$(jq -r    '.fail_count // 0'           "$STATE_FILE" 2>/dev/null || echo "0")
ok_count=$(jq -r      '.ok_count // 0'             "$STATE_FILE" 2>/dev/null || echo "0")
last_change=$(jq -r   '.last_change // 0'          "$STATE_FILE" 2>/dev/null || echo "0")
last_fail_time=$(jq -r '.last_fail_time // 0'      "$STATE_FILE" 2>/dev/null || echo "0")

# Sanitize: ensure numeric
fail_count=$(printf '%d' "$fail_count" 2>/dev/null || echo "0")
ok_count=$(printf '%d' "$ok_count" 2>/dev/null || echo "0")
last_change=$(printf '%d' "$last_change" 2>/dev/null || echo "0")
last_fail_time=$(printf '%d' "$last_fail_time" 2>/dev/null || echo "0")

# ── TIME DECAY: expire stale failures after FAIL_EXPIRE_SECS ─────────────────
if [ $failed -eq 0 ] && [ $fail_count -gt 0 ] && [ $last_fail_time -gt 0 ]; then
    age=$((now - last_fail_time))
    if [ $age -ge $FAIL_EXPIRE_SECS ]; then
        fail_count=0
    fi
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

# ── STATE TRANSITION ──────────────────────────────────────────────────────────
new_state="$current_state"

if [ $fail_count -ge 4 ] && [ "$current_state" != "FAILOVER" ]; then
    new_state="FAILOVER"
elif [ $ok_count -ge 8 ] && [ "$current_state" != "NORMAL" ]; then
    new_state="NORMAL"
fi

# ── COOLDOWN: prevent flapping (120s minimum between state changes) ───────────
if [ "$new_state" != "$current_state" ]; then
    elapsed=$((now - last_change))
    if [ $elapsed -lt 120 ]; then
        new_state="$current_state"
    else
        last_change=$now
    fi
fi

# ── ATOMIC STATE WRITE ────────────────────────────────────────────────────────
TMP_STATE="$STATE_FILE.tmp"
jq -n \
    --arg  st "$new_state" \
    --argjson fc "$fail_count" \
    --argjson oc "$ok_count" \
    --argjson lc "$last_change" \
    --argjson lf "$last_fail_time" \
    '{state:$st, fail_count:$fc, ok_count:$oc, last_change:$lc, last_fail_time:$lf}' \
    > "$TMP_STATE" 2>/dev/null && mv "$TMP_STATE" "$STATE_FILE"
