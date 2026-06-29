#!/bin/sh

set -e

REPO_ROOT=$(pwd)
BUILD_DIR="/tmp/ipk_build_root"

# Clean up any existing build dir
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR/control"
mkdir -p "$BUILD_DIR/data/usr/bin"
mkdir -p "$BUILD_DIR/data/etc/init.d"
mkdir -p "$BUILD_DIR/data/etc/config"

# Copy payload files
cp "$REPO_ROOT/package/files/usr/bin/dns_smart_probe.sh" "$BUILD_DIR/data/usr/bin/"
cp "$REPO_ROOT/package/files/usr/bin/dns_smart_apply.sh" "$BUILD_DIR/data/usr/bin/"
cp "$REPO_ROOT/package/files/etc/init.d/dns-smart-routing" "$BUILD_DIR/data/etc/init.d/"
cp "$REPO_ROOT/package/files/etc/config/dns-smart-routing" "$BUILD_DIR/data/etc/config/"

# Write control metadata
cat << CTRL > "$BUILD_DIR/control/control"
Package: dns-smart-routing
Version: 1.0.0-1
Depends: jq
Section: net
Architecture: all
Maintainer: Recoba86
Description: Lightweight DNS smart routing system for OpenWRT
CTRL

# Write postinst script
cat << 'POST' > "$BUILD_DIR/control/postinst"
#!/bin/sh
if [ -z "${IPKG_INSTROOT}" ]; then
    echo "Enabling and starting dns-smart-routing service..."
    /etc/init.d/dns-smart-routing enable
    /etc/init.d/dns-smart-routing start
fi
exit 0
POST
chmod +x "$BUILD_DIR/control/postinst"

# Write prerm script
cat << 'PRERM' > "$BUILD_DIR/control/prerm"
#!/bin/sh
if [ -z "${IPKG_INSTROOT}" ]; then
    echo "Stopping and disabling dns-smart-routing service..."
    /etc/init.d/dns-smart-routing stop
    /etc/init.d/dns-smart-routing disable
fi
exit 0
PRERM
chmod +x "$BUILD_DIR/control/prerm"

# Create debian-binary
echo "2.0" > "$BUILD_DIR/debian-binary"

# Determine OS for tar flags
OS=$(uname -s)
if [ "$OS" = "Darwin" ]; then
    TAR_OPTS="--no-xattrs --no-mac-metadata --format=ustar"
else
    TAR_OPTS=""
fi

# Pack control.tar.gz and data.tar.gz
(cd "$BUILD_DIR/control" && COPYFILE_DISABLE=1 tar $TAR_OPTS -czf ../control.tar.gz .)
(cd "$BUILD_DIR/data" && COPYFILE_DISABLE=1 tar $TAR_OPTS -czf ../data.tar.gz .)

# Pack final .ipk file
(cd "$BUILD_DIR" && COPYFILE_DISABLE=1 tar $TAR_OPTS -czf "$REPO_ROOT/dns-smart-routing_1.0.0.ipk" debian-binary control.tar.gz data.tar.gz)

# Clean up
rm -rf "$BUILD_DIR"

echo "Build successful: dns-smart-routing_1.0.0.ipk"
