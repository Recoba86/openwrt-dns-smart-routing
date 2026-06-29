#!/bin/sh

LOCKFILE="/tmp/dns-smart-routing.lock"
STATE_DIR="/etc/dns-smart-routing"
STATE_FILE="$STATE_DIR/state.json"
FINGERPRINT_FILE="$STATE_DIR/runtime_fingerprint.json"

# Concurrency lock protection
if [ -f "$LOCKFILE" ]; then
    now=$(date +%s)
    lock_time=$(date -r "$LOCKFILE" +%s 2>/dev/null || stat -c %Y "$LOCKFILE" 2>/dev/null || echo 0)
    elapsed=$((now - lock_time))
    if [ $elapsed -lt 120 ]; then
        echo "Lock active (age ${elapsed}s). Overlapping run prevented."
        exit 0
    fi
fi

# Create lock
echo "$$" > "$LOCKFILE"
# Ensure clean exit
trap 'rm -f "$LOCKFILE"; exit' INT TERM EXIT

mkdir -p "$STATE_DIR"

# Read UCI configuration
enabled=$(uci -q get dns-smart-routing.global.enabled || echo "1")
if [ "$enabled" != "1" ]; then
    exit 0
fi

# Initialize state JSON if missing or corrupt
if [ ! -f "$STATE_FILE" ] || [ ! -s "$STATE_FILE" ] || ! jq -e . "$STATE_FILE" >/dev/null 2>&1; then
    echo '{"state":"CLEAN","consecutive_fail":0,"consecutive_ok":0,"last_change":0}' > "$STATE_FILE"
fi

local_dns=$(uci -q get dns-smart-routing.global.local_dns || echo "127.0.0.1#15353")

resolve_ips() {
    domain=$1
    resolver=$2
    nslookup $domain $resolver 2>/dev/null | awk "
        /Address/ {
            if (\$0 ~ /$resolver/) next;
            for (i=1; i<=NF; i++) {
                if (\$i ~ /^[0-9]+\\.[0-9]+\\.[0-9]+\\.[0-9]+\$/) {
                    print \$i
                }
            }
        }
    " | sort | tr '\n' ',' | sed 's/,$//'
}

dns_query() {
    resolver=$1
    domain=$2
    
    START=$(awk '{print $1}' /proc/uptime)
    ips=$(resolve_ips "$domain" "$resolver")
    END=$(awk '{print $1}' /proc/uptime)
    
    if [ -n "$ips" ]; then
        latency_ms=$(echo "$START $END" | awk '{print int(($2 - $1) * 1000)}')
        echo "$ips|$latency_ms"
    else
        echo "-1"
    fi
}

DOMAINS="google.com cloudflare.com bamkhodro.com"
failed=0
poisoned=0

for domain in $DOMAINS; do
    res1=$(dns_query "1.1.1.1" "$domain")
    res2=$(dns_query "8.8.8.8" "$domain")
    
    ips1=$(echo "$res1" | cut -d'|' -f1)
    lat1=$(echo "$res1" | cut -d'|' -f2)
    
    ips2=$(echo "$res2" | cut -d'|' -f1)
    lat2=$(echo "$res2" | cut -d'|' -f2)
    
    # 1. Liveness check
    if { [ -z "$lat1" ] || [ "$lat1" -lt 0 ] || [ "$lat1" -gt 300 ]; } || { [ -z "$lat2" ] || [ "$lat2" -lt 0 ] || [ "$lat2" -gt 300 ]; }; then
        if [ "$domain" != "bamkhodro.com" ]; then
            failed=1
        fi
    fi
    
    # 2. Poisoning check (on international domains only)
    if [ "$domain" != "bamkhodro.com" ]; then
        if [ "$ips1" != "$ips2" ] || [ -z "$ips1" ] || [ -z "$ips2" ]; then
            poisoned=1
        fi
    fi
done

# Read current state
current_state=$(jq -r ".state // \"CLEAN\"" "$STATE_FILE")
consecutive_fail=$(jq -r ".consecutive_fail // 0" "$STATE_FILE")
consecutive_ok=$(jq -r ".consecutive_ok // 0" "$STATE_FILE")
last_change=$(jq -r ".last_change // 0" "$STATE_FILE")

new_state="$current_state"

if [ $poisoned -eq 1 ]; then
    new_state="DEGRADED"
    consecutive_fail=0
    consecutive_ok=0
else
    if [ $failed -eq 1 ]; then
        consecutive_fail=$((consecutive_fail + 1))
        consecutive_ok=0
    else
        consecutive_ok=$((consecutive_ok + 1))
        consecutive_fail=0
    fi
    
    if [ $consecutive_fail -ge 4 ] && [ "$current_state" != "BROKEN" ]; then
        new_state="BROKEN"
    elif [ $consecutive_ok -ge 8 ] && [ "$current_state" != "CLEAN" ]; then
        new_state="CLEAN"
    fi
fi

# Enforce Cooldown (120 seconds lock)
if [ "$new_state" != "$current_state" ]; then
    now=$(date +%s)
    elapsed=$((now - last_change))
    if [ $elapsed -lt 120 ]; then
        new_state="$current_state"
    else
        last_change=$now
    fi
fi

# Atomic state write
jq -n --arg st "$new_state" \
      --argjson cf "$consecutive_fail" \
      --argjson co "$consecutive_ok" \
      --argjson lc "$last_change" \
      '{state: $st, consecutive_fail: $cf, consecutive_ok: $co, last_change: $lc}' \
      > "$STATE_FILE.tmp"
sync
mv "$STATE_FILE.tmp" "$STATE_FILE"

# Desync verification and repair trigger
if [ -f "$FINGERPRINT_FILE" ]; then
    expected_state=$(jq -r ".state // \"\"" "$FINGERPRINT_FILE")
    saved_hash=$(jq -r ".config_hash // \"\"" "$FINGERPRINT_FILE")
    current_hash=$(md5sum /tmp/dnsmasq_dynamic_servers.conf 2>/dev/null | awk '{print $1}')
    
    if [ "$expected_state" != "$new_state" ] || [ "$saved_hash" != "$current_hash" ]; then
        /usr/bin/dns_smart_apply.sh
    fi
else
    /usr/bin/dns_smart_apply.sh
fi
