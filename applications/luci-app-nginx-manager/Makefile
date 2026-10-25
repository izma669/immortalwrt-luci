include $(TOPDIR)/rules.mk

LUCI_TITLE:=LuCI Nginx Manager
LUCI_DEPENDS:=+luci-base +luci-compat +nginx +ffprobe +ffmpeg
LUCI_PKGARCH:=all

define Package/luci-app-nginx-manager/postinst
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] && exit 0
chmod +x /usr/bin/music-center-daemon 2>/dev/null
chmod +x /usr/bin/music-center-reader.lua 2>/dev/null
chmod +x /usr/bin/music-center-restart 2>/dev/null
chmod +x /usr/bin/music-cover-fetch 2>/dev/null
chmod +x /usr/bin/nginx-manager.lua 2>/dev/null
chmod +x /etc/init.d/music-center 2>/dev/null
chmod +x /etc/uci-defaults/99-music-center 2>/dev/null
exit 0
endef

include ../../luci.mk
