#!/bin/sh

LOCKFILE="/tmp/dns-smart-routing.lock"
STATE_DIR="/etc/dns-smart-routing"
STATE_FILE="$STATE_DIR/state.json"

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
    echo '{"state":"default","consecutive_fail":0,"consecutive_ok":0,"last_change":0}' > "$STATE_FILE"
fi

local_dns=$(uci -q get dns-smart-routing.global.local_dns || echo "127.0.0.1#15353")
local_ip=$(echo "$local_dns" | cut -d'#' -f1)
local_port=$(echo "$local_dns" | cut -d'#' -f2)

dns_query() {
    resolver_ip=$1
    resolver_port=$2
    domain=$3
    
    START=$(awk '{print $1}' /proc/uptime)
    if [ -n "$resolver_port" ]; then
        nslookup -port=$resolver_port $domain $resolver_ip >/dev/null 2>&1
    else
        nslookup $domain $resolver_ip >/dev/null 2>&1
    fi
    exit_code=$?
    END=$(awk '{print $1}' /proc/uptime)
    
    if [ $exit_code -eq 0 ]; then
        echo $(echo "$START $END" | awk '{print int(($2 - $1) * 1000)}')
    else
        echo "-1"
    fi
}

DOMAINS="google.com cloudflare.com bamkhodro.com"
default_failed=0

for domain in $DOMAINS; do
    # Test fixed resolvers
    lat1=$(dns_query "1.1.1.1" "" "$domain")
    lat2=$(dns_query "8.8.8.8" "" "$domain")
    lat_local=$(dns_query "$local_ip" "$local_port" "$domain")
    
    # Evaluate default path health based on international domains
    if [ "$domain" != "bamkhodro.com" ]; then
        if { [ "$lat1" -lt 0 ] || [ "$lat1" -gt 300 ]; } && { [ "$lat2" -lt 0 ] || [ "$lat2" -gt 300 ]; }; then
            default_failed=1
        fi
    fi
done

# Read current state
current_state=$(jq -r ".state // \"default\"" "$STATE_FILE")
consecutive_fail=$(jq -r ".consecutive_fail // 0" "$STATE_FILE")
consecutive_ok=$(jq -r ".consecutive_ok // 0" "$STATE_FILE")
last_change=$(jq -r ".last_change // 0" "$STATE_FILE")

if [ $default_failed -eq 1 ]; then
    consecutive_fail=$((consecutive_fail + 1))
    consecutive_ok=0
else
    consecutive_ok=$((consecutive_ok + 1))
    consecutive_fail=0
fi

new_state="$current_state"
if [ $consecutive_fail -ge 4 ] && [ "$current_state" != "local" ]; then
    new_state="local"
elif [ $consecutive_ok -ge 8 ] && [ "$current_state" != "default" ]; then
    new_state="default"
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
