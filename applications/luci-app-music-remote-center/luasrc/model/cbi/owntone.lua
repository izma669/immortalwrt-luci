-- Copyright 2020 Lean <coolsnowwolf@gmail.com>
-- Licensed to the public under the Apache License 2.0.

m = Map("owntone")
m.title = translate("Music Remote Center")
m.description = translate("Music Remote Center is a DAAP (iTunes Remote), MPD (Music Player Daemon) and RSP (Roku) media server.")

m:section(SimpleSection).template  = "owntone/owntone_status"

s = m:section(TypedSection, "owntone")
s.addremove = false
s.anonymous = true

enable = s:option(Flag, "enabled", translate("Enabled"))
enable.default = "0"
enable.rmempty = false

port = s:option(Value, "port", translate("Port"))
port.rmempty = false
port.datatype = "port"

db_path = s:option(Value, "db_path", translate("Database File Path"))
db_path.default = "/opt/owntone-songs3.db"
db_path.rmempty = false

directories = s:option(Value, "directories", translate("Music Directorie Path"))
directories.default = "/opt/music"
directories.rmempty = false

readme = s:option(DummyValue, "readme", translate("Readme"))
readme.description = translate("About iOS Remote Pairing: <br />1. Open the web interface <br /> 2. Start iPhone Remote APP, go to Settings, Add Library<br />3. Enter the pair code in the web interface")

-- ===== 重启服务按钮 =====
local restart_btn = s:option(Button, "restart_btn", translate("Restart Service"))
restart_btn.inputstyle = "reload"
function restart_btn.write(self, section)
    luci.sys.call("/etc/init.d/owntone restart >/dev/null 2>&1")
end

-- ===== 重载USB声卡内核模块按钮 =====
local reload_usb_btn = s:option(Button, "reload_usb_btn", translate("Reload USB Sound Loadable Kernel Module"))
reload_usb_btn.inputstyle = "reload"
function reload_usb_btn.write(self, section)
    -- 先卸载，再加载USB声卡内核模块
    luci.sys.call("rmmod snd_usb_audio >/dev/null 2>&1; modprobe snd_usb_audio >/dev/null 2>&1")
end

-- ===== 初始化所有声卡按钮 (alsactl init) =====
local alsa_init_btn = s:option(Button, "alsa_init_btn", translate("Initialize All Sound Cards"))
alsa_init_btn.inputstyle = "reload"
function alsa_init_btn.write(self, section)
    luci.sys.call("alsactl init >/dev/null 2>&1")
end

return m
