local m, s, o

m = Map("gmediarender", translate("GMediaRender"),
    translate("GMediaRender is a UPnP/DLNA audio renderer. " ..
        "It allows you to push audio from your phone or computer to this device."))

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

o = s:option(Value, "logfile", translate("Log File"),
    translate("Path to log file (leave empty to disable logging)"))
o.default = "/var/log/gmediarender.log"
o.rmempty = true

s = m:section(NamedSection, "main", "gmediarender", translate("Status"))
s.anonymous = true

o = s:option(DummyValue, "_status", translate("Service Status"))
o.template = "gmediarender/status"

return m