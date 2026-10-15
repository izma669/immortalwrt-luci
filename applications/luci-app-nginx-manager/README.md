# OpenWrt DLNA 媒体播放器 (Player.html + LuCI 后端)

这是一个基于 OpenWrt 路由器的轻量级媒体播放器，通过 Nginx 提供 HTTP 服务，支持将本地视频投屏到 DLNA 设备（如 Apple TV、AirPin 等），并内置了进度条控制与状态同步机制。

## ✨ 功能特性
- 📺 支持 SSDP 自动发现局域网 DLNA 设备，也支持手动输入 IP/端口强制投屏。
- ⏯️ 投屏后可通过网页控制播放、暂停、停止。
- 📊 进度条控制：自动获取本地视频时长，支持拖动跳转（兼容支持的 DLNA 接收端）。
- 🔄 混合模式同步：本地走时 + 远端状态轮询，尽量保持两端进度一致。
- 🖼️ 音频模式：播放音乐时支持自动获取封面并轮播背景图。
- 📄 支持 PDF、TXT、图片等多种格式预览。

## 🚀 部署说明

### 1. 部署前端 `player.html`
将 `player.html` 上传到路由器的 `/www/` 目录下。
> ⚠️ **注意**：务必确保文件保存为 **UTF-8 (无 BOM)** 编码，否则页面会出现中文乱码方块。

### 2. 部署后端 `nginx-manager.lua`
将 `nginx-manager.lua` 上传到路由器的 `/usr/lib/lua/luci/controller/` 目录下（覆盖原文件）。

### 3. 清理 LuCI 缓存并重启服务
在路由器 SSH 终端执行以下命令：
```bash
rm -rf /tmp/luci-*
rm -rf /tmp/luci-indexcache
/etc/init.d/nginx reload
# 如果 LuCI 运行在 uhttpd 上：
/etc/init.d/uhttpd restart
