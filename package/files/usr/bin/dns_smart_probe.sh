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
    echo '{"state":"NORMAL","fail_count":0,"ok_count":0,"last_change":0}' > "$STATE_FILE"
fi

dns_query() {
    resolver=$1
    domain=$2
    
    START=$(awk '{print $1}' /proc/uptime)
    nslookup $domain $resolver >/dev/null 2>&1
    exit_code=$?
    END=$(awk '{print $1}' /proc/uptime)
    
    if [ $exit_code -eq 0 ]; then
        echo $(echo "$START $END" | awk '{print int(($2 - $1) * 1000)}')
    else
        echo "-1"
    fi
}

DOMAINS="google.com cloudflare.com"
failed=0

for domain in $DOMAINS; do
    lat1=$(dns_query "1.1.1.1" "$domain")
    lat2=$(dns_query "8.8.8.8" "$domain")
    
    # Check default path health (fails if both 1.1.1.1 and 8.8.8.8 are slow/offline)
    if { [ -z "$lat1" ] || [ "$lat1" -lt 0 ] || [ "$lat1" -gt 300 ]; } && { [ -z "$lat2" ] || [ "$lat2" -lt 0 ] || [ "$lat2" -gt 300 ]; }; then
        failed=1
        break
    fi
done

# Read current state
current_state=$(jq -r ".state // \"NORMAL\"" "$STATE_FILE")
fail_count=$(jq -r ".fail_count // 0" "$STATE_FILE")
ok_count=$(jq -r ".ok_count // 0" "$STATE_FILE")
last_change=$(jq -r ".last_change // 0" "$STATE_FILE")

if [ $failed -eq 1 ]; then
    fail_count=$((fail_count + 1))
    ok_count=0
else
    ok_count=$((ok_count + 1))
    fail_count=0
fi

new_state="$current_state"
if [ $fail_count -ge 4 ] && [ "$current_state" != "FAILOVER" ]; then
    new_state="FAILOVER"
elif [ $ok_count -ge 8 ] && [ "$current_state" != "NORMAL" ]; then
    new_state="NORMAL"
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
      --argjson fc "$fail_count" \
      --argjson oc "$ok_count" \
      --argjson lc "$last_change" \
      '{state: $st, fail_count: $fc, ok_count: $oc, last_change: $lc}' \
      > "$STATE_FILE.tmp"
sync
mv "$STATE_FILE.tmp" "$STATE_FILE"
