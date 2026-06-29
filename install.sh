#!/bin/sh

echo "Installing dns-smart-routing..."

# Require opkg
if ! which opkg >/dev/null 2>&1; then
    echo "Error: opkg not found. Run this on an OpenWRT router."
    exit 1
fi

# Install jq only if missing
if ! which jq >/dev/null 2>&1; then
    echo "Installing jq dependency..."
    opkg update && opkg install jq || {
        echo "Error: failed to install jq. Aborting."
        exit 1
    }
fi

# Create required directories
mkdir -p /etc/dns-smart-routing /usr/bin /etc/init.d /etc/config

# Install scripts
cp package/files/usr/bin/dns_smart_probe.sh /usr/bin/dns_smart_probe.sh
cp package/files/usr/bin/dns_smart_apply.sh /usr/bin/dns_smart_apply.sh
cp package/files/etc/init.d/dns-smart-routing /etc/init.d/dns-smart-routing
cp package/files/etc/config/dns-smart-routing /etc/config/dns-smart-routing

chmod +x /usr/bin/dns_smart_probe.sh \
         /usr/bin/dns_smart_apply.sh \
         /etc/init.d/dns-smart-routing

# Enable and start service (handles dnsmasq + cron registration idempotently)
/etc/init.d/dns-smart-routing enable
/etc/init.d/dns-smart-routing start

echo "dns-smart-routing installed successfully."
