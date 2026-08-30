# Copyright (C) 2018-2021 Lienol <lawlienol@gmail.com>
#
# This is free software, licensed under the Apache License, Version 2.0 .
#

include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-ipsec-server
PKG_VERSION:=20211223
PKG_RELEASE:=12

PKG_MAINTAINER:=Lienol <lawlienol@gmail.com>

LUCI_TITLE:=LuCI support for IPSec VPN Server
LUCI_DEPENDS:=+kmod-tun +luci-lib-jsonc +strongswan +strongswan-minimal +strongswan-mod-kernel-libipsec +strongswan-mod-openssl +strongswan-mod-xauth-generic +xl2tpd
LUCI_PKGARCH:=all

define Package/$(PKG_NAME)/conffiles
/etc/config/luci-app-ipsec-server
endef

include $(TOPDIR)/feeds/luci/luci.mk

# 插入的 install 段 —— 为 init 脚本设置可执行权限
define Package/$(PKG_NAME)/install
    $(INSTALL_DIR) $(1)/etc/init.d
    $(INSTALL_BIN) /root/etc/init.d/luci-app-ipsec-server $(1)/etc/init.d/
	chmod 755 $(1)/etc/init.d/luci-app-ipsec-server      # 添加执行权限
endef
# =============================

# call BuildPackage - OpenWrt buildroot signature
