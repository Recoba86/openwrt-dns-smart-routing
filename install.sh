#!/bin/sh

echo "Installing dns-smart-routing..."

# Install dependencies
opkg update
opkg install jq netcat

# Create directories
mkdir -p /etc/dns-smart-routing
mkdir -p /usr/bin
mkdir -p /etc/init.d
mkdir -p /etc/config

# Copy files
cp package/files/usr/bin/dns_smart_probe.sh /usr/bin/
cp package/files/usr/bin/dns_smart_apply.sh /usr/bin/
cp package/files/etc/init.d/dns-smart-routing /etc/init.d/
cp package/files/etc/config/dns-smart-routing /etc/config/

# Make executable
chmod +x /usr/bin/dns_smart_probe.sh
chmod +x /usr/bin/dns_smart_apply.sh
chmod +x /etc/init.d/dns-smart-routing

# Start service
/etc/init.d/dns-smart-routing enable
/etc/init.d/dns-smart-routing start

# Restart dnsmasq once
/etc/init.d/dnsmasq restart

echo "dns-smart-routing installed successfully!"
