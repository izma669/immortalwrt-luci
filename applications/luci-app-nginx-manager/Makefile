include $(TOPDIR)/rules.mk

LUCI_TITLE:=LuCI Nginx Manager
LUCI_DEPENDS:=+luci-base +luci-compat +nginx +ffprobe +ffmpeg
LUCI_PKGARCH:=all

include ../../luci.mk

# 显式安装：可执行脚本用 INSTALL_BIN（0755），配置用 INSTALL_CONF，
# 其余 Lua / HTML / CSS / JS 用 INSTALL_DATA（0644）。
define Package/luci-app-nginx-manager/install
	$(INSTALL_DIR) $(1)/usr/lib/lua/luci/controller
	$(INSTALL_DATA) ./usr/lib/lua/luci/controller/*.lua $(1)/usr/lib/lua/luci/controller/

	$(INSTALL_DIR) $(1)/usr/lib/lua/luci/model/cbi
	$(INSTALL_DATA) ./usr/lib/lua/luci/model/cbi/*.lua $(1)/usr/lib/lua/luci/model/cbi/

	$(INSTALL_DIR) $(1)/usr/lib/lua/luci/view/nginx-manager
	$(INSTALL_DATA) ./usr/lib/lua/luci/view/nginx-manager/*.htm $(1)/usr/lib/lua/luci/view/nginx-manager/

	$(INSTALL_DIR) $(1)/usr/bin
	$(INSTALL_BIN) ./usr/bin/music-center-daemon $(1)/usr/bin/
	$(INSTALL_BIN) ./usr/bin/music-center-reader.lua $(1)/usr/bin/
	$(INSTALL_BIN) ./usr/bin/music-center-restart $(1)/usr/bin/
	$(INSTALL_BIN) ./usr/bin/music-cover-fetch $(1)/usr/bin/
	$(INSTALL_BIN) ./usr/bin/nginx-manager.lua $(1)/usr/bin/

	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) ./etc/init.d/music-center $(1)/etc/init.d/

	$(INSTALL_DIR) $(1)/etc/uci-defaults
	$(INSTALL_BIN) ./etc/uci-defaults/99-music-center $(1)/etc/uci-defaults/

	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_CONF) ./etc/config/music-center $(1)/etc/config/

	$(INSTALL_DIR) $(1)/etc/music-center/servers
	$(INSTALL_CONF) ./etc/music-center/nginx.conf $(1)/etc/music-center/
	$(INSTALL_CONF) ./etc/music-center/servers/880.conf $(1)/etc/music-center/servers/
	$(INSTALL_CONF) ./etc/music-center/servers/888.conf $(1)/etc/music-center/servers/

	$(INSTALL_DIR) $(1)/www/music-center
	$(INSTALL_DATA) ./www/player.html $(1)/www/
	$(INSTALL_DATA) ./www/caster.html $(1)/www/
	$(INSTALL_DATA) ./www/hls.min.js $(1)/www/
	$(INSTALL_DATA) ./www/mpegts.min.js $(1)/www/
	$(INSTALL_DATA) ./www/music-center/index.html $(1)/www/music-center/
	$(INSTALL_DATA) ./www/music-center/app.css $(1)/www/music-center/
	$(INSTALL_DATA) ./www/music-center/app.js $(1)/www/music-center/
	$(INSTALL_DATA) ./www/music-center/favicon.svg $(1)/www/music-center/
endef

# 安装后再兜底 chmod，避免 Windows 打包或 opkg 解包丢执行位。
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
