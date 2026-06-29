# v1.0.0 - Lightweight DNS Failover for OpenWRT

## What is this?
`dns-smart-routing` is a small OpenWRT package that helps `dnsmasq` switch to a local DNS resolver when public DNS becomes unreliable.

It is designed for users who already have a local DNS resolver such as Passwall/Xray DNS running on the router.

## Key Features
- Minimal NORMAL / FAILOVER state model
- 2 consecutive DNS failures required before FAILOVER
- 1 successful DNS check restores NORMAL
- Prevents false healthy detection by ignoring resolver/server IPs in nslookup output
- Repairs missing or corrupted state.json automatically
- Idempotent cron and dnsmasq integration
- jq-only dependency

## What it does not do
- It is not a VPN
- It is not a proxy
- It does not tunnel traffic
- It does not modify firewall rules
- It does not modify routing tables
- It does not bypass filtering by itself

## Default behavior
- Public DNS check:
  - 1.1.1.1
  - 8.8.8.8
- Test domains:
  - google.com
  - cloudflare.com
- Default local DNS failover target:
  - 127.0.0.1#15353

## Install
Download the attached IPK file and install:

```bash
opkg update
opkg install jq
opkg install /tmp/dns-smart-routing_1.0.0.ipk
/etc/init.d/dns-smart-routing enable
/etc/init.d/dns-smart-routing start
```

## Verify
```bash
cat /etc/dns-smart-routing/state.json
cat /tmp/dnsmasq_dynamic_servers.conf
grep 'servers-file=/tmp/dnsmasq_dynamic_servers.conf' /etc/dnsmasq.conf
grep 'dns_smart_probe.sh' /etc/crontabs/root
```

## Notes
This package only helps with DNS-related instability. It does not replace a VPN, proxy, or local resolver.
