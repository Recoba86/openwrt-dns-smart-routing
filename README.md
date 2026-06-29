# dns-smart-routing (Production Safe Edition)

A lightweight, stable OpenWRT DNS failover system. It detects default DNS resolution failures or high latency, and switches dnsmasq resolvers to a local DNS resolver (such as Xray/Passwall DNS) to prevent connectivity dropouts.

## Features & 2-State System
- **NORMAL**: Queries use default WAN DNS servers (dnsmasq dynamic override file is empty).
- **FAILOVER**: Queries are directed to the local DNS resolver at `127.0.0.1#15353`.
- **Transitions**: Switches to `FAILOVER` after 4 consecutive failure cycles (latency >300ms or resolver timeout). Returns to `NORMAL` after 8 consecutive successes.
- **Flapping Protection**: Enforces a 120-second cooldown period between state changes.

## What this project is NOT
- ❌ NOT a VPN
- ❌ NOT a proxy or bypass tool
- ❌ Does NOT bypass filtering
- ❌ Does NOT modify routing tables or firewall rules

## Safety Guarantees
- POSIX ash shell compatible.
- Concurrency locking to prevent duplicate cron runs.
- Non-recursive design (probing and applying processes are strictly decoupled).
- Atomic configuration writing.

## Installation

```bash
chmod +x install.sh
./install.sh
```
