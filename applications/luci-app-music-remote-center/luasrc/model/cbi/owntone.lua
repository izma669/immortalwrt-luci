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

-- 定义三个子面板
s:tab("basic", translate("基本设置"))
s:tab("playback", translate("播放控制选项"))
s:tab("advanced", translate("高级设置"))

-- ==================== 基本设置 ====================
enable = s:taboption("basic", Flag, "enabled", translate("Enabled"))
enable.default = "0"
enable.rmempty = false

port = s:taboption("basic", Value, "port", translate("Port"))
port.rmempty = false
port.datatype = "port"

db_path = s:taboption("basic", Value, "db_path", translate("Database File Path"))
db_path.default = "/opt/owntone-songs3.db"
db_path.rmempty = false

directories = s:taboption("basic", Value, "directories", translate("Music Directorie Path"))
directories.default = "/opt/music"
directories.rmempty = false

readme = s:taboption("basic", DummyValue, "readme", translate("Readme"))
readme.description = translate("About iOS Remote Pairing: <br />1. Open the web interface <br /> 2. Start iPhone Remote APP, go to Settings, Add Library<br />3. Enter the pair code in the web interface")

-- ===== 重启服务按钮 =====
local restart_btn = s:taboption("basic", Button, "restart_btn", translate("重启Owntone服务器"))
restart_btn.inputstyle = "reload"
function restart_btn.write(self, section)
    sys.call("/etc/init.d/owntone restart >/dev/null 2>&1")
end

-- ==================== 播放控制选项 ====================
autoplay = s:taboption("playback", Flag, "autoplay", translate("自动播放音乐库"))
autoplay.default = "0"
autoplay.rmempty = false
autoplay.description = translate("Owntone 启动后自动把整个音乐库加入队列并开始播放。")

autoplay_random = s:taboption("playback", Flag, "autoplay_random", translate("随机选曲"))
autoplay_random.default = "0"
autoplay_random.rmempty = false
autoplay_random:depends("autoplay", "1")

autoplay_repeat = s:taboption("playback", Flag, "autoplay_repeat", translate("列表循环"))
autoplay_repeat.default = "0"
autoplay_repeat.rmempty = false
autoplay_repeat:depends("autoplay", "1")

-- ===== 定时音量调整（新增 4 个时间点）=====
for i = 1, 4 do
    local time_opt = s:taboption("playback", Value, "time" .. i, translate("时间点 " .. i .. " (HH:MM)"))
    time_opt.default = ""
    time_opt.rmempty = true
    time_opt.placeholder = "07:00"
    time_opt.datatype = "string"
    time_opt.validate = function(self, value)
        if value and value ~= "" then
            if not value:match("^%d%d:%d%d$") then
                return nil, translate("时间格式必须为 HH:MM")
            end
            local h, m = value:match("^(%d%d):(%d%d)$")
            h, m = tonumber(h), tonumber(m)
            if h < 0 or h > 23 or m < 0 or m > 59 then
                return nil, translate("时间无效")
            end
        end
        return value
    end

    local vol_opt = s:taboption("playback", Value, "volume" .. i, translate("音量 " .. i .. " (%)"))
    vol_opt.default = ""
    vol_opt.rmempty = true
    vol_opt.datatype = "range(0,100)"
    vol_opt.placeholder = "50"
end

-- ===== 应用定时音量设置按钮 =====
local apply_btn = s:taboption("playback", Button, "apply_volume_schedule", translate("应用定时音量设置"))
apply_btn.inputstyle = "apply"
function apply_btn.write(self, section)
    local uci = self.map.uci
    local cfg = self.map.config

    -- 关键：先把内存里的表单值 commit 到磁盘
    uci:commit(cfg)

    local card_idx   = uci:get(cfg, section, "card") or "plughw:0"
    local mixer_dev  = uci:get(cfg, section, "mixer_device") or "hw:0"
    local mixer_ctrl = uci:get(cfg, section, "mixer") or ""

    -- 调试日志
    local log = io.open("/tmp/owntone_btn.log", "a")
    if log then
        log:write(string.format("%s apply: card=%s dev=%s mixer=%s\n",
            os.date("%Y-%m-%d %H:%M:%S"),
            tostring(card_idx), tostring(mixer_dev), tostring(mixer_ctrl)))
    end

    if mixer_ctrl == "" then
        if log then log:write("  mixer 为空，放弃\n"); log:close() end
        return
    end

    local card_num = tostring(card_idx):match(":(%d+)") or "0"

    -- 收集新 cron 行
    local new_lines = {}
    for i = 1, 4 do
        local t = uci:get(cfg, section, "time" .. i) or ""
        local v = uci:get(cfg, section, "volume" .. i) or ""
        if log then log:write(string.format("  #%d time=%s vol=%s\n", i, t, v)) end
        if t ~= "" and v ~= "" then
            local hh, mm = t:match("^(%d?%d):(%d%d)$")
            if hh and mm then
                table.insert(new_lines, string.format(
                    "%d %d * * * amixer -c %s -D %s sset '%s' %s%% >/dev/null 2>&1",
                    tonumber(mm), tonumber(hh),
                    card_num, mixer_dev, mixer_ctrl, v))
            end
        end
    end

    -- 读写 crontab
    local crontab = "/etc/crontabs/root"
    local kept = {}
    local f = io.open(crontab, "r")
    if f then
        for line in f:lines() do
            if not line:match("amixer%s+%-c%s+%d+") then
                table.insert(kept, line)
            end
        end
        f:close()
    end
    for _, l in ipairs(new_lines) do
        table.insert(kept, l)
    end

    f = io.open(crontab, "w")
    if f then
        f:write(table.concat(kept, "\n") .. "\n")
        f:close()
        if log then log:write("  写入 " .. #new_lines .. " 条 cron\n") end
    elseif log then
        log:write("  错误：无法写 crontab\n")
    end
    if log then log:close() end

    -- 重启 cron
    sys.call("/etc/init.d/cron restart >/dev/null 2>&1")
end

-- ==================== 高级设置 ====================

-- ===== 重载USB声卡内核模块按钮 =====
local reload_usb_btn = s:taboption("advanced", Button, "reload_usb_btn", translate("Reload USB Sound Loadable Kernel Module"))
reload_usb_btn.inputstyle = "reload"
function reload_usb_btn.write(self, section)
    sys.call("rmmod snd_usb_audio >/dev/null 2>&1; modprobe snd_usb_audio >/dev/null 2>&1")
end

-- ===== 初始化所有声卡按钮 (alsactl init) =====
local alsa_init_btn = s:taboption("advanced", Button, "alsa_init_btn", translate("Initialize All Sound Cards"))
alsa_init_btn.inputstyle = "reload"
function alsa_init_btn.write(self, section)
    sys.call("alsactl init >/dev/null 2>&1")
end

------------------------------------------------------------
-- ★ 声卡设备
------------------------------------------------------------
card = s:taboption("advanced", ListValue, "card", translate("Audio Card"),
                translate("ALSA 声卡设备。plughw 会自动转换采样率/格式，兼容性更好。"))
card:value("plughw:0", "plughw:0 (推荐)")
card:value("hw:0",     "hw:0 (严格)")
card:value("default",  "default")
card.default = "plughw:0"
card.rmempty = false

------------------------------------------------------------
-- ★ 混音器设备
------------------------------------------------------------
mixer_device = s:taboption("advanced", ListValue, "mixer_device", translate("Mixer Device"))
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

mixer = s:taboption("advanced", ListValue, "mixer", translate("Mixer Control"),
                 translate("列表来自 <code>amixer -c 0 scontrols</code>。选择“(不控制音量)”则跳过音量同步。"))
mixer:value("", translate("(不控制音量)"))
for name, _ in pairs(mixers) do
    mixer:value(name, name)
end
mixer.default = ""
mixer.rmempty = true

------------------------------------------------------------
-- ★ 探测状态提示
------------------------------------------------------------
status = s:taboption("advanced", DummyValue, "_mixer_status", translate("Detection Status"))
status.rawhtml = true
status.cfgvalue = function(self, section)
    if mixer_count == 0 then
        return "<span style='color:#c00'>未探测到混音器。请确认已安装 <code>alsa-utils</code>，且 USB 声卡已插入。</span>"
    end
    return string.format("<span style='color:#080'>检测到 %d 个混音器控制。</span>", mixer_count)
end

return m
