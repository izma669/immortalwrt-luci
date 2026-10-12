include $(TOPDIR)/rules.mk

LUCI_TITLE:=LuCI Nginx Manager
LUCI_DEPENDS:=+luci-base +nginx
LUCI_PKGARCH:=all

include ../../luci.mk

define Package/luci-app-nginx-manager/postinst
#!/bin/sh
# 把播放器部署到 nginx 根目录（/mnt）
if [ -f "/www/player.html" ]; then
    if [ -d "/mnt" ] && [ -w "/mnt" ]; then
        cp -f /www/player.html /mnt/player.html 2>/dev/null
    fi
fi
exit 0
endef

# call BuildPackage - OpenWrt buildroot signature
