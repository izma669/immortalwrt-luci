local m, s, o

m = Map("gmediarender", translate("GMediaRender"),
    translate("GMediaRender is a UPnP/DLNA audio renderer. " ..
        "It allows you to push audio from your phone or computer to this device."))

-- ==========================================
-- 1. 状态模块
-- ==========================================
s = m:section(NamedSection, "main", "gmediarender", translate("Status"))
s.anonymous = true

o = s:option(DummyValue, "_status", translate("Service Status"))
o.template = "gmediarender/status"

-- ==========================================
-- 2. Now Playing 模块
-- ==========================================
s = m:section(NamedSection, "main", "gmediarender", translate("Now Playing"))
s.anonymous = true

o = s:option(DummyValue, "_nowplaying", translate("Current Track"))
o.template = "gmediarender/nowplaying"

-- ==========================================
-- 3. 基本设置模块
-- ==========================================
s = m:section(NamedSection, "main", "gmediarender", translate("Basic Settings"))
s.anonymous = true
s.addremove = false

o = s:option(Flag, "enabled", translate("Enable"),
    translate("Enable GMediaRender service"))
o.default = "0"
o.rmempty = false

o = s:option(Value, "friendly_name", translate("Friendly Name"),
    translate("The name that appears on DLNA controllers"))
o.default = "OpenWrt-Speaker"
o.rmempty = false

o = s:option(Value, "interface", translate("Listen Interface"),
    translate("IP address or interface name to bind (e.g. br-lan or 192.168.1.1)"))
o.default = "br-lan"
o.rmempty = false

o = s:option(Value, "port", translate("Port"),
    translate("UPnP event port (default 49152)"))
o.datatype = "port"
o.default = "49152"
o.rmempty = false

-- 日志总开关
o = s:option(Flag, "enable_log", translate("Enable Logging"),
    translate("Write playback log to file. Required for the Now Playing display."))
o.default = "1"
o.rmempty = false

-- 日志文件路径
o = s:option(Value, "logfile", translate("Log File"),
    translate("Path to log file (leave empty to disable logging)"))
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
s = m:section(NamedSection, "main", "gmediarender", translate("Service Control"))
s.anonymous = true
s.addremove = false

o = s:option(Button, "_reload", translate("Reload GMediaRender"))
o.inputtitle = translate("Reload Service")
o.inputstyle = "apply"
o.write = function()
    luci.sys.call("/etc/init.d/gmediarender restart >/dev/null 2>&1")
end

return m
