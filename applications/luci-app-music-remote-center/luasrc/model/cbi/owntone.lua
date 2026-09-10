-- Copyright 2020 Lean <coolsnowwolf@gmail.com>
-- Licensed to the public under the Apache License 2.0.

local sys = require "luci.sys"

m = Map("owntone")
m.title = translate("Music Remote Center")
m.description = translate("Music Remote Center is a DAAP (iTunes Remote), MPD (Music Player Daemon) and RSP (Roku) media server.")

m:section(SimpleSection).template = "owntone/owntone_status"

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
local restart_btn = s:option(Button, "restart_btn", translate("Owntone""Restart Service"))
restart_btn.inputstyle = "reload"
function restart_btn.write(self, section)
    luci.sys.call("/etc/init.d/owntone restart >/dev/null 2>&1")
end

-- ===== 重载USB声卡内核模块按钮 =====
local reload_usb_btn = s:option(Button, "reload_usb_btn", translate("Reload USB Sound Loadable Kernel Module"))
reload_usb_btn.inputstyle = "reload"
function reload_usb_btn.write(self, section)
    luci.sys.call("rmmod snd_usb_audio >/dev/null 2>&1; modprobe snd_usb_audio >/dev/null 2>&1")
end

-- ===== 初始化所有声卡按钮 (alsactl init) =====
local alsa_init_btn = s:option(Button, "alsa_init_btn", translate("Initialize All Sound Cards"))
alsa_init_btn.inputstyle = "reload"
function alsa_init_btn.write(self, section)
    luci.sys.call("alsactl init >/dev/null 2>&1")
end

------------------------------------------------------------
-- ★ 声卡设备
------------------------------------------------------------
card = s:option(ListValue, "card", translate("Audio Card"),
                translate("ALSA 声卡设备。plughw 会自动转换采样率/格式，兼容性更好。"))
card:value("plughw:0", "plughw:0 (推荐)")
card:value("hw:0",     "hw:0 (严格)")
card:value("default",  "default")
card.default = "plughw:0"
card.rmempty = false

------------------------------------------------------------
-- ★ 混音器设备
------------------------------------------------------------
mixer_device = s:option(ListValue, "mixer_device", translate("Mixer Device"))
mixer_device:value("hw:0", "hw:0")
mixer_device:value("hw:1", "hw:1")
mixer_device.default = "hw:0"
mixer_device.rmempty = false

------------------------------------------------------------
-- ★ 动态读取混音器列表
------------------------------------------------------------
local function get_mixers(card_index)
    local list = {}
    local out = sys.exec("amixer -c " .. tostring(card_index) .. " scontrols 2>/dev/null")
    if out and #out > 0 then
        -- 匹配 Simple mixer control 'PCM',0  ->  PCM
        for name in out:gmatch("Simple mixer control%s+'([^']+)'") do
            list[name] = name
        end
    end
    return list
end

local mixers = get_mixers(0)
local mixer_count = 0
for _ in pairs(mixers) do mixer_count = mixer_count + 1 end

mixer = s:option(ListValue, "mixer", translate("Mixer Control"),
                 translate("列表来自 <code>amixer -c 0 scontrols</code>。选择“(不控制音量)”则跳过音量同步。"))
mixer:value("", translate("(不控制音量)"))
for name, _ in pairs(mixers) do
    mixer:value(name, name)
end
mixer.default = ""
mixer.rmempty = false

------------------------------------------------------------
-- ★ 探测状态提示
------------------------------------------------------------
status = s:option(DummyValue, "_mixer_status", translate("Detection Status"))
status.rawhtml = true
status.cfgvalue = function(self, section)
    if mixer_count == 0 then
        return "<span style='color:#c00'>未探测到混音器。请确认已安装 <code>alsa-utils</code>，且 USB 声卡已插入。</span>"
    end
    return string.format("<span style='color:#080'>检测到 %d 个混音器控制。</span>", mixer_count)
end

return m
