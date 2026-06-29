#!/bin/sh

LOCKFILE="/tmp/dns-smart-routing.lock"
BOOTID_FILE="/tmp/dns-smart-routing.bootid"
STATE_DIR="/etc/dns-smart-routing"
STATE_FILE="$STATE_DIR/state.json"
FAIL_EXPIRE_SECS=300
NOISE_WINDOW_SECS=120

# ── BOOT ID ───────────────────────────────────────────────────────────────────
# Derived from system boot epoch (stable for entire boot session).
# /tmp is tmpfs → cleared on reboot → old locks auto-invalid.
# Bootid adds protection against fast-reboot PID reuse edge case.
_current_bootid() {
    local now uptime_int
    now=$(date +%s 2>/dev/null || echo "0")
    uptime_int=$(awk '{printf "%d", $1}' /proc/uptime 2>/dev/null || echo "0")
    echo $((now - uptime_int))
}

# Ensure bootid file exists (resilient against init not having run yet)
if [ ! -f "$BOOTID_FILE" ]; then
    _current_bootid > "$BOOTID_FILE" 2>/dev/null || true
fi
SYSTEM_BOOTID=$(cat "$BOOTID_FILE" 2>/dev/null || _current_bootid)

# ── BOOT-AWARE HYBRID LOCK ────────────────────────────────────────────────────
# Lock format: "<PID>:<bootid>"
# Valid ONLY when: PID alive + cmdline matches + bootid matches current boot.
# Any mismatch → stale → remove and retry.

_acquire_lock() {
    if [ -f "$LOCKFILE" ]; then
        local lock_content lpid lock_bootid
        lock_content=$(cat "$LOCKFILE" 2>/dev/null)
        lpid="${lock_content%%:*}"
        lock_bootid="${lock_content##*:}"

        # Bootid mismatch → always stale (different boot or corrupted)
        if [ "$lock_bootid" != "$SYSTEM_BOOTID" ]; then
            rm -f "$LOCKFILE" 2>/dev/null
        elif [ -n "$lpid" ] && kill -0 "$lpid" 2>/dev/null; then
            # Same boot, PID alive → validate via cmdline
            local cmdline
            cmdline=$(cat "/proc/$lpid/cmdline" 2>/dev/null | tr '\0' ' ')
            if echo "$cmdline" | grep -q "dns_smart_probe"; then
                return 1  # Live confirmed process — exit gracefully
            fi
            # Alive but not our script → ambiguous → fail-safe exit
            return 1
        else
            # Same boot, PID dead → remove stale lock
            rm -f "$LOCKFILE" 2>/dev/null
        fi
    fi

    # Atomic create via noclobber
    set -C
    ( printf '%s:%s\n' "$$" "$SYSTEM_BOOTID" > "$LOCKFILE" ) 2>/dev/null
    local rc=$?
    set +C

    # Write failure = ro-fs or inode exhaustion → exit gracefully
    [ $rc -ne 0 ] && return 1

    # Race validation: confirm our PID:bootid was written
    local written written_pid
    written=$(cat "$LOCKFILE" 2>/dev/null)
    written_pid="${written%%:*}"
    [ "$written_pid" != "$$" ] && return 1

    return 0
}

if ! _acquire_lock; then
    exit 0
fi

# Guarantee lockfile cleanup on all exit paths
trap 'rm -f "$LOCKFILE"; exit' INT TERM EXIT

mkdir -p "$STATE_DIR" 2>/dev/null || exit 0

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

# ── DNS IP VALIDATION (no awk; bad-IP filtering) ─────────────────────────────
# Returns space-separated valid IPs from nslookup output, or empty string.
_get_valid_ips() {
    local out="$1"
    local result=""
    local ip
    for ip in $(echo "$out" | grep -E -o '([0-9]{1,3}\.){3}[0-9]{1,3}'); do
        case "$ip" in
            0.0.0.0|127.*|255.255.255.255) continue ;;
            *) result="$result $ip" ;;
        esac
    done
    echo "$result"
}

# ── EVALUATION LOOP: availability-based DNS check ────────────────────────────
# FAILED if: either resolver returns no valid IPv4, or nslookup fails/times out.
# OK if: BOTH resolvers return at least one valid IPv4 (no further comparison).
DOMAINS="google.com cloudflare.com"
failed=0
now=$(date +%s 2>/dev/null || echo "0")

for domain in $DOMAINS; do
    out1=$(nslookup "$domain" "1.1.1.1" 2>/dev/null)
    out2=$(nslookup "$domain" "8.8.8.8" 2>/dev/null)

    ips1=$(_get_valid_ips "$out1")
    ips2=$(_get_valid_ips "$out2")

    # Both resolvers must return at least one valid IPv4
    if [ -z "$ips1" ] || [ -z "$ips2" ]; then
        failed=1
        break
    fi
done

# ── READ CURRENT STATE (safe fallbacks) ──────────────────────────────────────
current_state=$(jq -r    '.state           // "NORMAL"' "$STATE_FILE" 2>/dev/null || echo "NORMAL")
fail_count=$(jq -r        '.fail_count      // 0'        "$STATE_FILE" 2>/dev/null || echo "0")
ok_count=$(jq -r          '.ok_count        // 0'        "$STATE_FILE" 2>/dev/null || echo "0")
last_change=$(jq -r       '.last_change     // 0'        "$STATE_FILE" 2>/dev/null || echo "0")
last_fail_time=$(jq -r    '.last_fail_time  // 0'        "$STATE_FILE" 2>/dev/null || echo "0")
pending_state=$(jq -r     '.pending_state   // ""'        "$STATE_FILE" 2>/dev/null || echo "")
pending_count=$(jq -r     '.pending_count   // 0'         "$STATE_FILE" 2>/dev/null || echo "0")
last_eval_result=$(jq -r  '.last_eval_result // -1'       "$STATE_FILE" 2>/dev/null || echo "-1")
last_eval_time=$(jq -r    '.last_eval_time  // 0'         "$STATE_FILE" 2>/dev/null || echo "0")

# Sanitize integers
fail_count=$(printf '%d'       "$fail_count"       2>/dev/null || echo "0")
ok_count=$(printf '%d'         "$ok_count"         2>/dev/null || echo "0")
last_change=$(printf '%d'      "$last_change"      2>/dev/null || echo "0")
last_fail_time=$(printf '%d'   "$last_fail_time"   2>/dev/null || echo "0")
pending_count=$(printf '%d'    "$pending_count"    2>/dev/null || echo "0")
last_eval_result=$(printf '%d' "$last_eval_result" 2>/dev/null || echo "-1")
last_eval_time=$(printf '%d'   "$last_eval_time"   2>/dev/null || echo "0")

# ── SOFT CONSENSUS FILTER (noise immunity) ────────────────────────────────────
# Commit evaluation only when 2 consecutive identical results occur within
# NOISE_WINDOW_SECS. Single samples are discarded (no state update).
eval_confirmed=0
l1=$(printf '%d' "${last_eval_result:-0}" 2>/dev/null || echo 0)
l2=$(printf '%d' "${failed:-0}" 2>/dev/null || echo 0)
if [ "$l1" -eq "$l2" ] 2>/dev/null; then
    time_since=$((now - last_eval_time))
    if [ $time_since -ge 0 ] && [ $time_since -le $NOISE_WINDOW_SECS ]; then
        eval_confirmed=1
    fi
fi

last_eval_result=$failed
last_eval_time=$now

# Not confirmed → persist only eval metadata, no state update
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

local_failed=$(printf '%d' "${failed:-0}" 2>/dev/null || echo 0)
local_fail_count=$(printf '%d' "${fail_count:-0}" 2>/dev/null || echo 0)
local_last_fail_time=$(printf '%d' "${last_fail_time:-0}" 2>/dev/null || echo 0)
local_now=$(printf '%d' "${now:-0}" 2>/dev/null || echo 0)
local_expire=$(printf '%d' "${FAIL_EXPIRE_SECS:-300}" 2>/dev/null || echo 300)

if [ "$local_failed" = "0" ] && [ "$local_fail_count" -gt 0 ] 2>/dev/null; then
    age=$((local_now - local_last_fail_time))
    [ $age -ge $local_expire ] && fail_count=0
fi

# ── RAW DESIRED STATE ─────────────────────────────────────────────────────────
desired_state="$current_state"
[ $fail_count -ge 4 ] && [ "$current_state" != "FAILOVER" ] && desired_state="FAILOVER"
[ $ok_count   -ge 8 ] && [ "$current_state" != "NORMAL"   ] && desired_state="NORMAL"

# ── HYSTERESIS: 2 consecutive evaluation windows before committing ────────────
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
# On any write/mv failure: exit 0 silently — current state preserved on disk.
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

mv "$TMP_STATE" "$STATE_FILE" 2>/dev/null || { rm -f "$TMP_STATE" 2>/dev/null; exit 0; }
