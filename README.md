# dns-smart-routing (Production Safe Edition)

Lightweight DNS failover helper for OpenWRT.

This package helps OpenWRT users who experience unstable DNS access to some websites or services, particularly on restricted, heavily filtered, or unreliable networks (such as in Iran).

## What problem it solves
On unstable networks, default public DNS resolution (via WAN DNS) often experiences packet loss, high latency, or DNS poisoning/tampering. This package monitors connection health and automatically routes DNS queries to a local secure resolver when WAN DNS degrades, preventing browser timeouts and dropouts.

---

## What it DOES:
- **DNS Health Monitoring**: Actively queries public DNS upstreams `1.1.1.1` and `8.8.8.8`.
- **Automatic resolver switching**: Updates dnsmasq dynamic upstreams cleanly without dropping existing connections.
- **Failover state preservation**: Employs a robust 2-state micro model (NORMAL & FAILOVER).

## What it DOES NOT do:
- ❌ **NOT a VPN or Proxy**: It does not tunnel, proxy, or redirect your device traffic.
- ❌ **Does NOT bypass censorship directly**: It does not replace tools like Passwall, Xray, or shadow socks, but works alongside them.
- ❌ **Does NOT modify system rules**: It makes zero changes to your OpenWRT firewall (iptables/nftables) or routing tables.

---

## How it works (2-State Model)
- **NORMAL**: WAN DNS is healthy. The dynamic dynamic servers-file is empty; DNS queries resolve through default WAN upstreams.
- **FAILOVER**: Switches to FAILOVER state if public DNS queries fail for **2 consecutive cycles**. All DNS queries are then routed to the local secure resolver.
- **Recovery**: Restores to NORMAL state immediately after **1 successful DNS check**.

---

## Installation

### Method 1: Using the one-line installer (Recommended)
```bash
wget -O - https://raw.githubusercontent.com/Recoba86/openwrt-dns-smart-routing/main/install.sh | sh
```

### Method 2: Manual IPK installation
Download the built `.ipk` package from our [v1.0.0 Release Page](https://github.com/Recoba86/openwrt-dns-smart-routing/releases/tag/v1.0.0) and run:
```bash
opkg update
opkg install jq
opkg install /tmp/dns-smart-routing_1.0.0.ipk
/etc/init.d/dns-smart-routing enable
/etc/init.d/dns-smart-routing start
```

---

## Configuration
The package uses standard OpenWRT unified configuration interface (UCI). The configuration file is located at `/etc/config/dns-smart-routing`:

```ini
config dns-smart-routing 'global'
    option enabled '1'
    option local_dns '127.0.0.1#15353'
```
- **enabled**: Set to `1` to enable, or `0` to disable the background probing.
- **local_dns**: The target local resolver address. Defaults to `127.0.0.1#15353` (standard port for Xray/Passwall local DNS).

---

## Usage & Verification
To monitor status or manage the service, run:

### Check current state:
```bash
cat /etc/dns-smart-routing/state.json
```
*(Outputs `{"state":"NORMAL"}` or `{"state":"FAILOVER"}`)*

### Check active servers-file dynamic configuration:
```bash
cat /tmp/dnsmasq_dynamic_servers.conf
```

### Check service status:
```bash
/etc/init.d/dns-smart-routing status
```

---

## Compatibility & Requirements
- **OpenWRT**: Compatible with 19.07, 21.02, 22.03, 23.05 and newer.
- **Resolver**: Configured to work natively with **dnsmasq**.
- **Dependencies**: Requires `jq` package for state file JSON parser processing. No `netcat/nc` required.

## Safety & Stability
- Zero firewall/routing dependencies.
- Atomic state file writes to prevent filesystem corruption under sudden power loss.
- Independent probing & applying cycles (no lock collisions or deadlocks).
