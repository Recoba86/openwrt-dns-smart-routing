# dns-smart-routing

A lightweight DNS smart routing system for OpenWRT routers. It dynamically detects domain resolution issues (timeouts, basic DNS poisoning/hijacks) and adjusts dnsmasq upstream resolvers dynamically to maintain DNS reliability.

## Problems Solved
- **DNS Instability**: Unstable or intermittent DNS resolution in restricted networks.
- **DNS Timeout**: High latency or dropped queries when resolving external domains.
- **DNS Poisoning**: Basic detection of tampered or hijacked DNS responses.

## What it does NOT do
- ❌ NOT a VPN
- ❌ NOT a proxy or bypass tool
- ❌ Does NOT change routing tables
- ❌ Does NOT modify firewall rules (iptables/nftables)

## How it works

```text
  [ Cron Check (Every 1m) ]
              │
              ▼
    [ Probe DNS Servers ] ──► (Resolves google.com, cloudflare.com, bamkhodro.com)
              │
              ▼
   [ Hysteresis Decision ] ──► (4 Fails -> Xray/Local DNS; 8 Successes -> Default DNS)
              │
              ▼
   [ SIGHUP Reload dnsmasq ] ──► (Atomic update of servers-file)
```

## Installation

```bash
chmod +x install.sh
./install.sh
```

## Safety Guarantees
- Idempotent configuration management.
- Cooldown period (120s minimum) to prevent route flapping.
- Zero network interruptions (only dnsmasq configuration reload occurs).
