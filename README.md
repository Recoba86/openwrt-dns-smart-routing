# dns-smart-routing (v2 Deployed)

A lightweight DNS smart routing system for OpenWRT routers. It dynamically detects domain resolution issues (timeouts, basic DNS poisoning/hijacks) and adjusts dnsmasq upstream resolvers dynamically through a 3-state machine.

## Problems Solved
- **DNS Instability**: Unstable or intermittent DNS resolution in restricted networks (including Iran).
- **DNS Timeout**: High latency or dropped queries when resolving external domains.
- **DNS Poisoning**: Active detection of tampered or hijacked DNS responses via resolver cross-comparison.

## What it does NOT do
- ❌ NOT a VPN
- ❌ NOT a proxy or bypass tool
- ❌ Does NOT change routing tables
- ❌ Does NOT modify firewall rules (iptables/nftables)

## How it works (3-State Model)
- **CLEAN**: Default DNS path (empty override).
- **DEGRADED**: Mixed fallback. Both public resolver and local resolver are listed in parallel (e.g. `server=1.1.1.1`, `server=8.8.8.8`, and `server=127.0.0.1#15353`).
- **BROKEN**: Local DNS path only (`server=127.0.0.1#15353`).

## Installation

```bash
chmod +x install.sh
./install.sh
```
