# dns-smart-routing (Production Safe Edition)

A lightweight, stable OpenWRT DNS failover system. It detects default DNS resolution failures or high latency, and switches dnsmasq resolvers to a local DNS resolver (such as Xray/Passwall DNS) to prevent connectivity dropouts.

## What it DOES:
- **Instability Detection**: Measures DNS health and latency against `1.1.1.1` and `8.8.8.8` directly.
- **Automatic Switching**: Safely switches upstreams dynamically through dnsmasq servers-file without connection dropouts.

## What it DOES NOT do:
- ❌ NOT a VPN
- ❌ NOT a proxy or bypass tool
- ❌ Does NOT bypass filtering
- ❌ Does NOT modify routing tables or firewall rules

## How it works (2-State System)
- **NORMAL**: Dynamic servers-file is empty; DNS queries resolve through default WAN DNS upstreams.
- **FAILOVER**: DNS queries resolve through the local resolver (`server=127.0.0.1#15353`).
- **Transitions**: Switches to `FAILOVER` after 4 consecutive failure cycles (latency >300ms or resolver timeout). Returns to `NORMAL` after 8 consecutive successes.
- **Flapping Protection**: Enforces a 120-second cooldown period between state changes.

## Installation

Run the one-line installer command on your router:
```bash
wget -O - https://raw.githubusercontent.com/Recoba86/openwrt-dns-smart-routing/main/install.sh | sh
```

## Safety Guarantees
- POSIX-ash shell compatible (BusyBox safe).
- Concurrency locking to prevent duplicate cron runs.
- Non-recursive design (probing and applying processes are strictly decoupled).
- Atomic configuration writing.
