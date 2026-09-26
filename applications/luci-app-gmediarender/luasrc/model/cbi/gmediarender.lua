local m, s, o

m = Map("gmediarender", "GR_DLNA音频接收器",
    "GMediaRender 是一个 UPnP/DLNA 音频渲染器，可以将手机或电脑上的音频推送到此设备播放。")

-- ==========================================
-- 1. 状态模块
-- ==========================================
s = m:section(NamedSection, "main", "gmediarender", "状态")
s.anonymous = true
o = s:option(DummyValue, "_status", "服务状态")
o.template = "gmediarender/status"

-- ==========================================
-- 2. 正在播放模块
-- ==========================================
s = m:section(NamedSection, "main", "gmediarender", "正在播放")
s.anonymous = true
o = s:option(DummyValue, "_nowplaying", "播放信息")
o.template = "gmediarender/nowplaying"

-- ==========================================
-- 3. 基本设置模块（所有配置项都放这里）
-- ==========================================
s = m:section(NamedSection, "main", "gmediarender", "基本设置")
s.anonymous = true
s.addremove = false

o = s:option(Flag, "enabled", "启用服务")
o.default = "0"
o.rmempty = false

o = s:option(Value, "friendly_name", "设备名称",
    "在 DLNA 客户端中显示的名称")
o.default = "OpenWrt-Speaker"
o.rmempty = false

o = s:option(Value, "interface", "监听接口",
    "绑定的 IP 地址或网卡名（如 br-lan 或 192.168.1.1）")
o.default = "br-lan"
o.rmempty = false

o = s:option(Value, "port", "端口",
    "UPnP 事件端口（默认 49152）")
o.datatype = "port"
o.default = "49152"
o.rmempty = false

o = s:option(Flag, "enable_log", "启用日志",
    "把日志写入文件后解析播放数据，这是“正在播放”显示功能所必需的")
o.default = "1"
o.rmempty = false

o = s:option(Value, "logfile", "日志文件",
    "日志文件路径（留空则关闭）")
o.default = "/var/log/gmediarender.log"
o.rmempty = true

o = s:option(Flag, "log_cleanup", "启用日志自动清理",
    "日志超过阈值时自动清空")
o.default = "1"
o.rmempty = false

o = s:option(Value, "log_limit_mb", "日志大小阈值 (MB)",
    "超过此大小将自动清空日志文件")
o.datatype = "uinteger"
o.default = "5"
o.rmempty = false
o:depends("log_cleanup", "1")

-- ==========================================
-- 4. 服务控制模块
-- ==========================================
s = m:section(NamedSection, "main", "gmediarender", "服务控制")
s.anonymous = true
s.addremove = false

o = s:option(Button, "_reload", "重载服务")
o.inputtitle = "立即重载"
o.inputstyle = "apply"
o.write = function()
    luci.sys.call("/etc/init.d/gmediarender restart >/dev/null 2>&1")
end

return m
