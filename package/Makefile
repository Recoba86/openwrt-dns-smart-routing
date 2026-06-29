include $(TOPDIR)/rules.mk

PKG_NAME:=dns-smart-routing
PKG_VERSION:=1.0.0
PKG_RELEASE:=1

include $(INCLUDE_DIR)/package.mk

define Package/dns-smart-routing
  SECTION:=net
  CATEGORY:=Network
  TITLE:=Lightweight DNS smart routing system for OpenWRT
  DEPENDS:=+jq
endef

define Package/dns-smart-routing/description
  Periodically tests DNS health and switches dnsmasq resolver to a local resolver during failures or high latency.
endef

define Build/Compile
	# Nothing to compile
endef

define Package/dns-smart-routing/install
	$(INSTALL_DIR) $(1)/usr/bin $(1)/etc/init.d $(1)/etc/config
	$(INSTALL_BIN) $(CURDIR)/files/usr/bin/dns_smart_probe.sh $(1)/usr/bin/
	$(INSTALL_BIN) $(CURDIR)/files/usr/bin/dns_smart_apply.sh $(1)/usr/bin/
	$(INSTALL_BIN) $(CURDIR)/files/etc/init.d/dns-smart-routing $(1)/etc/init.d/
	$(INSTALL_CONF) $(CURDIR)/files/etc/config/dns-smart-routing $(1)/etc/config/
endef

$(eval $(call BuildPackage,dns-smart-routing))
