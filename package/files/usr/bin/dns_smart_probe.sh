#!/bin/sh

STATE_DIR="/etc/dns-smart-routing"
STATE_FILE="$STATE_DIR/state.json"

mkdir -p "$STATE_DIR" 2>/dev/null

# Read UCI configuration
enabled=$(uci -q get dns-smart-routing.global.enabled 2>/dev/null || echo "1")
[ "$enabled" != "1" ] && exit 0

_get_valid_ips() {
    local ip
    for ip in $(echo "$1" | grep -E -o '([0-9]{1,3}\.){3}[0-9]{1,3}' 2>/dev/null); do
        case "$ip" in
            0.0.0.0|127.*|255.255.255.255) continue ;;
            *) echo "$ip" && return 0 ;;
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
    [ $rc1 -eq 0 ] && ips1=$(_get_valid_ips "$out1")
    [ $rc2 -eq 0 ] && ips2=$(_get_valid_ips "$out2")

    if [ -z "$ips1" ] || [ -z "$ips2" ]; then
        failed=1
        break
    fi
done

if [ $failed -eq 1 ]; then
    new_state="FAILOVER"
else
    new_state="NORMAL"
fi

# Atomic state write
TMP_STATE="${STATE_FILE}.tmp"
printf '{"state":"%s"}\n' "$new_state" > "$TMP_STATE" 2>/dev/null \
    && mv "$TMP_STATE" "$STATE_FILE" 2>/dev/null \
    || rm -f "$TMP_STATE" 2>/dev/null
