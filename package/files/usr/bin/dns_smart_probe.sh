#!/bin/sh

STATE_DIR="/etc/dns-smart-routing"
STATE_FILE="$STATE_DIR/state.json"

mkdir -p "$STATE_DIR"

# Read UCI configuration
enabled=$(uci -q get dns-smart-routing.global.enabled || echo "1")
if [ "$enabled" != "1" ]; then
    exit 0
fi

# Initialize state JSON if missing
if [ ! -f "$STATE_FILE" ] || [ ! -s "$STATE_FILE" ]; then
    echo '{"state":"default","consecutive_fail":0,"consecutive_ok":0,"last_change":0}' > "$STATE_FILE"
fi

DOMAINS="google.com cloudflare.com bamkhodro.com"
cycle_failed=0

for domain in $DOMAINS; do
    START=$(awk '{print $1}' /proc/uptime)
    nslookup $domain 1.1.1.1 >/dev/null 2>&1
    exit_code=$?
    END=$(awk '{print $1}' /proc/uptime)
    
    if [ $exit_code -eq 0 ]; then
        latency_ms=$(echo "$START $END" | awk '{print int(($2 - $1) * 1000)}')
    else
        latency_ms=-1
    fi
    
    if [ $exit_code -ne 0 ] || [ $latency_ms -gt 300 ] || [ $latency_ms -lt 0 ]; then
        cycle_failed=1
        break
    fi
done

# Read current state
current_state=$(jq -r ".state // \"default\"" "$STATE_FILE")
consecutive_fail=$(jq -r ".consecutive_fail // 0" "$STATE_FILE")
consecutive_ok=$(jq -r ".consecutive_ok // 0" "$STATE_FILE")
last_change=$(jq -r ".last_change // 0" "$STATE_FILE")

if [ $cycle_failed -eq 1 ]; then
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

# Check Cooldown (120 seconds lock)
if [ "$new_state" != "$current_state" ]; then
    now=$(date +%s)
    elapsed=$((now - last_change))
    if [ $elapsed -lt 120 ]; then
        # Cooldown active, block transition
        new_state="$current_state"
    else
        # Transition allowed, update last_change
        last_change=$now
    fi
fi

# Save state
jq --arg st "$new_state" \
   --argjson cf "$consecutive_fail" \
   --argjson co "$consecutive_ok" \
   --argjson lc "$last_change" \
   '.state = $st | .consecutive_fail = $cf | .consecutive_ok = $co | .last_change = $lc' \
   "$STATE_FILE" > "$STATE_FILE.tmp" && mv "$STATE_FILE.tmp" "$STATE_FILE"
