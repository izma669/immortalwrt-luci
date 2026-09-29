-- Copyright 2020 Lean <coolsnowwolf@gmail.com>
-- Licensed to the public under the Apache License 2.0.

local sys = require "luci.sys"

m = Map("owntone")
m.title = translate("Music Remote Center")
m.description = translate("Music Remote Center is a DAAP (iTunes Remote), MPD (Music Player Daemon) and RSP (Roku) media server.")

-- 1. 正在播放状态框
m:section(SimpleSection).template = "owntone/owntone_status"

-- 2. 物理声卡音量滑块 + 当前声卡信息（保留在顶部）
local snd_vol_sec = m:section(SimpleSection)
snd_vol_sec.anonymous = true
snd_vol_sec.addremove = false

local snd_vol = snd_vol_sec:option(DummyValue, "_snd_vol", translate("物理声卡音量控制"))
snd_vol.rawhtml = true
snd_vol.default = [[
<div style="padding: 10px 0;">
    <div style="display: flex; align-items: center; gap: 12px; max-width: 400px;">
        <input type="range" id="hw_vol_slider" min="0" max="100" value="50" 
               style="flex: 1; cursor: pointer;"
               oninput="document.getElementById('hw_vol_val').innerText = this.value + '%'"
               onchange="window.applyHwVolume(this.value)">
        <span id="hw_vol_val" style="font-weight: bold; width: 45px; text-align: right;">--%</span>
    </div>
    <div id="snd_info" style="color: #666; font-size: 13px; margin-top: 6px;">正在读取声卡信息...</div>
</div>
<script type="text/javascript">
    window.currentCard = "0";
    window.currentControl = "Headphone";
    window.owntoneBaseUrl = '/cgi-bin/luci/admin/nas/owntone';

    window.loadSoundcardInfo = function() {
        var xhr = new XMLHttpRequest();
        xhr.open('GET', window.owntoneBaseUrl + '/get_soundcard_info', true);
        xhr.onreadystatechange = function() {
            if (xhr.readyState === 4 && xhr.status === 200) {
                try {
                    var res = JSON.parse(xhr.responseText);
                    if (res.success) {
                        window.currentCard = res.card;
                        window.currentControl = res.control;
                        var infoEl = document.getElementById('snd_info');
                        if (infoEl) {
                            infoEl.innerHTML = '当前声卡: <b>' + res.name + '</b> (hw:' + res.card + ') | 控制项: <b>' + res.control + '</b>';
                        }
                        var sliderEl = document.getElementById('hw_vol_slider');
                        var valEl = document.getElementById('hw_vol_val');
                        if (typeof res.volume === 'number') {
                            if (sliderEl) sliderEl.value = res.volume;
                            if (valEl) valEl.innerText = res.volume + '%';
                        }
                    }
                } catch(e) {}
            }
        };
        xhr.send();
    };

    window.applyHwVolume = function(val) {
        var xhr = new XMLHttpRequest();
        xhr.open('POST', window.owntoneBaseUrl + '/set_volume', true);
        xhr.setRequestHeader('Content-Type', 'application/x-www-form-urlencoded');
        xhr.setRequestHeader('X-Requested-With', 'XMLHttpRequest');
        xhr.send('volume=' + val + '&card=' + window.currentCard + '&control=' + window.currentControl);
    };

    setTimeout(window.loadSoundcardInfo, 300);
</script>
]]


-- ==================== 标签页定义 ====================
s = m:section(TypedSection, "owntone")
s.addremove = false
s.anonymous = true

s:tab("playback", translate("播放控制选项"))
s:tab("basic", translate("基本设置"))
s:tab("advanced", translate("高级设置"))
s:tab("logs",     translate("日志查看"))

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

-- ===== 定时音量调整（每个时间点包含：启用开关 + 时间 + 控制目标 + 音量） =====
for i = 1, 4 do
    -- 独立启用开关
    local enable_opt = s:taboption("playback", Flag, "enable_time" .. i, 
        translate("启用定时音量 " .. i))
    enable_opt.default = "0"
    enable_opt.rmempty = false
    enable_opt.description = translate("开启后才生效，关闭时下方时间、控制目标和音量输入框会自动折叠隐藏。")

    -- 时间
    local time_opt = s:taboption("playback", Value, "time" .. i, 
        translate("时间点 " .. i .. " (HH:MM)"))
    time_opt.default = ""
    time_opt.rmempty = true
    time_opt.placeholder = "07:00"
    time_opt.datatype = "string"
    time_opt:depends("enable_time" .. i, "1")
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

    -- 控制目标
    local target_opt = s:taboption("playback", ListValue, "target" .. i, 
        translate("控制目标 " .. i))
    target_opt:value("softvol", translate("OwnTone 软件音量（只影响本地播放）"))
    target_opt:value("hw",     translate("物理声卡音量（影响 AirPlay/DLNA/OwnTone 全部）"))
    target_opt.default = "softvol"
    target_opt.rmempty = false
    target_opt:depends("enable_time" .. i, "1")

    -- 音量
    local vol_opt = s:taboption("playback", Value, "volume" .. i, 
        translate("音量 " .. i .. " (%)"))
    vol_opt.default = ""
    vol_opt.rmempty = true
    vol_opt.datatype = "range(0,100)"
    vol_opt.placeholder = "50"
    vol_opt:depends("enable_time" .. i, "1")
end

-- ===== 应用定时音量设置按钮 =====
local apply_btn = s:taboption("playback", Button, "apply_volume_schedule", translate("应用定时音量设置"))
apply_btn.inputstyle = "apply"
function apply_btn.write(self, section)
    local uci = self.map.uci
    local cfg = self.map.config
    uci:commit(cfg)

    local sys = require "luci.sys"
    local fs = require "nixio.fs"

    -- 动态解析物理声卡编号和控制项，供 hw 目标使用
    local card_num, control_name = "0", "Headphone"
    if fs.access("/etc/asound.conf") then
        local conf = fs.readfile("/etc/asound.conf") or ""
        local name = conf:match('pcm%s+"hw:([^,]+),')
        if name then
            if name:match("^%d+$") then
                card_num = name
            else
                local cards = sys.exec("cat /proc/asound/cards 2>/dev/null")
                for num, cname in cards:gmatch("(%d+) %[([^%]]+)%]") do
                    if cname:gsub("%s+$", "") == name then
                        card_num = num
                        break
                    end
                end
            end
        end
    end
    local scontrols = sys.exec("amixer -c " .. card_num .. " scontrols 2>/dev/null")
    if scontrols:match("'Headphone'") then control_name = "Headphone"
    elseif scontrols:match("'Master'") then control_name = "Master"
    elseif scontrols:match("'PCM'") then control_name = "PCM"
    else
        local first = scontrols:match("'([^']+)'")
        if first then control_name = first end
    end

    local new_lines = {}
    for i = 1, 4 do
        local enabled = uci:get(cfg, section, "enable_time" .. i) or "0"
        if enabled == "1" then
            local t = uci:get(cfg, section, "time" .. i) or ""
            local v = uci:get(cfg, section, "volume" .. i) or ""
            local target = uci:get(cfg, section, "target" .. i) or "softvol"
            if t ~= "" and v ~= "" then
                local hh, mm = t:match("^(%d?%d):(%d%d)$")
                if hh and mm then
                    if target == "hw" then
                        -- 控制物理声卡硬件音量
                        table.insert(new_lines, string.format(
                            "%d %d * * * amixer -c %s sset '%s' %s%% unmute >/dev/null 2>&1",
                            tonumber(mm), tonumber(hh), card_num, control_name, v))
                    else
                        -- 控制 OwnTone 软件音量
                        table.insert(new_lines, string.format(
                            "%d %d * * * curl -s -X PUT 'http://127.0.0.1:3689/api/player/volume?volume=%s' >/dev/null 2>&1",
                            tonumber(mm), tonumber(hh), v))
                    end
                end
            end
        end
    end

    -- 清理旧的音量任务（amixer 或 curl 音量），保留其他 cron 行
    local crontab = "/etc/crontabs/root"
    local kept = {}
    local f = io.open(crontab, "r")
    if f then
        for line in f:lines() do
            if not line:match("amixer%s+%-c%s+%d+") and not line:match("api/player/volume") then
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
    end
    sys.call("/etc/init.d/cron restart >/dev/null 2>&1")
end

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

-- ==================== 高级设置 ====================
-- ===== 刷新并自动配置声卡 =====
local snd_refresh = s:taboption("advanced", DummyValue, "_snd_refresh", translate("刷新并自动配置声卡"))
snd_refresh.rawhtml = true
snd_refresh.default = [[
<div style="padding: 10px 0;">
    <button type="button" class="cbi-button cbi-button-action" id="refresh_snd_btn" onclick="refreshSoundcard()">刷新并自动配置声卡</button>
    <div style="color: #888; font-size: 12px; line-height: 1.7; margin-top: 8px;">
        <b>作用：</b>检测当前 USB 声卡的型号和编号，自动将声卡信息和独立音量控制（softvol）写入 <code>/etc/asound.conf</code>，并重启 OwnTone、AirPlay、DLNA 服务。<br>
        <b>使用时机：</b>仅在<b>更换 USB 声卡后手动点击一次</b>。平时调节音量请直接用上方“物理声卡音量控制”滑块。
    </div>
</div>
<script type="text/javascript">
    window.refreshSoundcard = function() {
        var btn = document.getElementById('refresh_snd_btn');
        if(!btn) return;
        btn.disabled = true;
        var oldText = btn.innerText;
        btn.innerText = '检测并写入中...';

        var xhr = new XMLHttpRequest();
        xhr.open('POST', window.owntoneBaseUrl + '/refresh_soundcard', true);
        xhr.setRequestHeader('X-Requested-With', 'XMLHttpRequest');
        xhr.onreadystatechange = function() {
            if (xhr.readyState === 4) {
                btn.disabled = false;
                btn.innerText = oldText;
                if (xhr.status === 200) {
                    try {
                        var res = JSON.parse(xhr.responseText);
                        if (res.success) {
                            window.currentCard = res.card;
                            window.currentControl = res.control;
                            var infoEl = document.getElementById('snd_info');
                            if (infoEl) {
                                infoEl.innerHTML = '当前声卡: <b>' + res.name + '</b> (hw:' + res.card + ') | 控制项: <b>' + res.control + '</b>';
                            }
                            var sliderEl = document.getElementById('hw_vol_slider');
                            var valEl = document.getElementById('hw_vol_val');
                            if (typeof res.volume === 'number') {
                                if (sliderEl) sliderEl.value = res.volume;
                                if (valEl) valEl.innerText = res.volume + '%';
                            }
                            alert('声卡配置已更新，服务已重启。');
                        } else {
                            alert('配置失败，请查看系统日志。');
                        }
                    } catch(e) {
                        alert('解析响应失败。');
                    }
                } else {
                    alert('请求失败 (HTTP ' + xhr.status + ')。');
                }
            }
        };
        xhr.send();
    };
</script>
]]

-- ===== 重载USB声卡内核模块按钮 =====
local reload_usb_btn = s:taboption("advanced", Button, "reload_usb_btn", translate("Reload USB Sound Loadable Kernel Module"))
reload_usb_btn.inputstyle = "reload"
function reload_usb_btn.write(self, section)
    sys.call("rmmod snd_usb_audio >/dev/null 2>&1; modprobe snd_usb_audio >/dev/null 2>&1")
end

-- ===== 初始化所有声卡按钮 =====
local alsa_init_btn = s:taboption("advanced", Button, "alsa_init_btn", translate("Initialize All Sound Cards"))
alsa_init_btn.inputstyle = "reload"
function alsa_init_btn.write(self, section)
    sys.call("alsactl init >/dev/null 2>&1")
end

-- ===== ALSA 诊断 =====
local diag = s:taboption("advanced", DummyValue, "_alsa_diag", translate("ALSA 诊断"))
diag.rawhtml = true
diag.cfgvalue = function(self, section)
    local cards = sys.exec("cat /proc/asound/cards 2>/dev/null") or ""
    local ctrls = sys.exec("amixer -c 0 scontrols 2>&1") or ""
    local asound = sys.exec("[ -f /etc/asound.conf ] && cat /etc/asound.conf || echo '(无 asound.conf)'") or ""

    local function esc(s)
        return (s:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"))
    end

    return string.format([[
<details>
<summary style="cursor:pointer;color:#06c;">点击展开原始输出</summary>
<b>/proc/asound/cards</b>
<pre style="background:#f7f7f7;padding:6px;border:1px solid #ddd;">%s</pre>
<b>amixer -c 0 scontrols</b>
<pre style="background:#f7f7f7;padding:6px;border:1px solid #ddd;">%s</pre>
<b>/etc/asound.conf</b>
<pre style="background:#f7f7f7;padding:6px;border:1px solid #ddd;">%s</pre>
</details>
]], esc(cards), esc(ctrls), esc(asound))
end

-- ==================== 日志查看 ====================
refresh_btn = s:taboption("logs", DummyValue, "_refresh_btn")
refresh_btn.rawhtml = true
refresh_btn.default = [[
<div style="margin-bottom:8px;">
  <button type="button" class="cbi-button cbi-button-action"
          onclick="location.reload();">刷新日志</button>
  <span style="margin-left:10px;color:#888;">
    共显示最近 200 行，切换子面板或点击按钮即可刷新
  </span>
</div>
]]

log_view = s:taboption("logs", TextValue, "_log_view", translate("Owntone 运行日志"))
log_view.rows     = 30
log_view.wrap     = "off"
log_view.readonly = true

function log_view.write(self, section, value)
end

function log_view.cfgvalue(self, section)
    local data
    data = sys.exec("logread -e owntone -e forked-daapd 2>/dev/null | tail -n 200")
    if not data or data == "" then
        data = sys.exec("[ -f /var/log/owntone.log ] && tail -n 200 /var/log/owntone.log 2>/dev/null")
    end
    if not data or data == "" then
        data = sys.exec("[ -f /tmp/log/owntone.log ] && tail -n 200 /tmp/log/owntone.log 2>/dev/null")
    end
    if not data or data == "" then
        data = translate("(暂无日志输出，请确认 Owntone 已启动)") .. "\n"
    end
    return data
end

return m
