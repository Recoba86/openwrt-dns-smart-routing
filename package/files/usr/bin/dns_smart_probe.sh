#!/bin/sh

STATE_DIR="/etc/dns-smart-routing"
STATE_FILE="$STATE_DIR/state.json"
FAIL_COUNT_FILE="/tmp/dns_smart_fail_count"

mkdir -p "$STATE_DIR" 2>/dev/null

enabled=$(uci -q get dns-smart-routing.global.enabled 2>/dev/null || echo "1")
[ "$enabled" != "1" ] && exit 0

# Validate and repair state if missing, empty, invalid JSON, or not in NORMAL/FAILOVER
is_corrupt=0
if [ ! -f "$STATE_FILE" ] || [ ! -s "$STATE_FILE" ]; then
    is_corrupt=1
else
    state_val=$(jq -r '.state' "$STATE_FILE" 2>/dev/null)
    if [ $? -ne 0 ] || [ "$state_val" != "NORMAL" -a "$state_val" != "FAILOVER" ]; then
        is_corrupt=1
    fi
fi

if [ $is_corrupt -eq 1 ]; then
    printf '{"state":"NORMAL"}\n' > "$STATE_FILE" 2>/dev/null
fi

_get_valid_ips() {
    local out="$1"
    local resolver="$2"
    local ip
    for ip in $(echo "$out" | grep -E -o '([0-9]{1,3}\.){3}[0-9]{1,3}' 2>/dev/null); do
        case "$ip" in
            0.0.0.0|127.*|255.255.255.255|1.1.1.1|8.8.8.8) continue ;;
            *)
                if [ -n "$resolver" ] && [ "$ip" = "$resolver" ]; then
                    continue
                fi
                echo "$ip"
                return 0
                ;;
        esac
    done
    return 1
}

DOMAINS="google.com cloudflare.com"
failed=0

for domain in $DOMAINS; do
    out1=$(nslookup "$domain" "1.1.1.1" 2>/dev/null)
    rc1=$?
    out2=$(nslookup "$domain" "8.8.8.8" 2>/dev/null)
    rc2=$?

    ips1=""
    ips2=""
    [ $rc1 -eq 0 ] && ips1=$(_get_valid_ips "$out1" "1.1.1.1")
    [ $rc2 -eq 0 ] && ips2=$(_get_valid_ips "$out2" "8.8.8.8")

    if [ -z "$ips1" ] || [ -z "$ips2" ]; then
        failed=1
        break
    fi
done

# Read current state
current_state=$(jq -r '.state // "NORMAL"' "$STATE_FILE" 2>/dev/null || echo "NORMAL")
new_state="$current_state"

if [ $failed -eq 1 ]; then
    # Increment failures count
    fail_count=$(cat "$FAIL_COUNT_FILE" 2>/dev/null || echo "0")
    fail_count=$((fail_count + 1))
    echo "$fail_count" > "$FAIL_COUNT_FILE" 2>/dev/null

    if [ $fail_count -ge 2 ] && [ "$current_state" != "FAILOVER" ]; then
        new_state="FAILOVER"
    fi
else
    # Recovery on 1 OK
    rm -f "$FAIL_COUNT_FILE" 2>/dev/null
    if [ "$current_state" != "NORMAL" ]; then
        new_state="NORMAL"
    fi
fi

# Write state atomically if changed
if [ "$new_state" != "$current_state" ]; then
    TMP_STATE="${STATE_FILE}.tmp"
    printf '{"state":"%s"}\n' "$new_state" > "$TMP_STATE" 2>/dev/null \
        && mv "$TMP_STATE" "$STATE_FILE" 2>/dev/null \
        || rm -f "$TMP_STATE" 2>/dev/null
fi
