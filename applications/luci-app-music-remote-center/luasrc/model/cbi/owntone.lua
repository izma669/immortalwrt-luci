-- Copyright 2020 Lean <coolsnowwolf@gmail.com>
-- Licensed to the public under the Apache License 2.0.

local sys = require "luci.sys"

m = Map("owntone")
m.title = translate("Music Remote Center")
m.description = translate("Music Remote Center is a DAAP (iTunes Remote), MPD (Music Player Daemon) and RSP (Roku) media server.")

-- 1. 正在播放状态框
m:section(SimpleSection).template = "owntone/owntone_status"

-- 2. 物理声卡音量与刷新（紧跟正在播放框下面，独立渲染，不进入标签页）
local snd_vol_sec = m:section(SimpleSection)
snd_vol_sec.anonymous = true
snd_vol_sec.addremove = false

local snd_vol = snd_vol_sec:option(DummyValue, "_snd_vol", translate("物理声卡音量控制"))
snd_vol.rawhtml = true
snd_vol.default = [[
<div style="padding: 10px 0;">
    <div style="display: flex; align-items: center; gap: 15px; margin-bottom: 10px;">
        <button type="button" class="cbi-button cbi-button-action" id="refresh_snd_btn" onclick="refreshSoundcard()">刷新并自动配置声卡</button>
        <span id="snd_info" style="color: #666; font-size: 13px;">点击上方按钮检测声卡信息</span>
    </div>
    <div style="display: flex; align-items: center; gap: 12px; max-width: 400px;">
        <input type="range" id="hw_vol_slider" min="0" max="100" value="50" 
               style="flex: 1; cursor: pointer;"
               oninput="document.getElementById('hw_vol_val').innerText = this.value + '%'"
               onchange="applyHwVolume(this.value)">
        <span id="hw_vol_val" style="font-weight: bold; width: 45px; text-align: right;">50%</span>
    </div>
</div>
<script type="text/javascript">
    var currentCard = "0";
    var currentControl = "Headphone";
    var owntoneBaseUrl = '/cgi-bin/luci/admin/nas/owntone';

    window.refreshSoundcard = function() {
        var btn = document.getElementById('refresh_snd_btn');
        var info = document.getElementById('snd_info');
        if(!btn) return;
        btn.disabled = true;
        btn.innerText = '检测并写入中...';
        info.innerHTML = '正在重新配置 ALSA 并重启服务，请稍候...';
        
        var xhr = new XMLHttpRequest();
        xhr.open('POST', owntoneBaseUrl + '/refresh_soundcard', true);
        xhr.setRequestHeader('X-Requested-With', 'XMLHttpRequest');
        xhr.onreadystatechange = function() {
            if (xhr.readyState === 4) {
                btn.disabled = false;
                btn.innerText = '刷新并自动配置声卡';
                if (xhr.status === 200) {
                    try {
                        var res = JSON.parse(xhr.responseText);
                        if (res.success) {
                            info.innerHTML = '当前声卡: <b>' + res.name + '</b> (hw:' + res.card + ') | 控制项: <b>' + res.control + '</b>';
                            document.getElementById('hw_vol_slider').value = res.volume;
                            document.getElementById('hw_vol_val').innerText = res.volume + '%';
                            currentCard = res.card;
                            currentControl = res.control;
                            alert('声卡配置已更新，服务已重启！');
                        } else {
                            info.innerHTML = '配置失败，请查看系统日志。';
                        }
                    } catch(e) { info.innerHTML = '解析响应失败。'; }
                } else {
                    info.innerHTML = '请求失败 (HTTP ' + xhr.status + ')。';
                }
            }
        };
        xhr.send();
    };

    window.applyHwVolume = function(val) {
        var xhr = new XMLHttpRequest();
        xhr.open('POST', owntoneBaseUrl + '/set_volume', true);
        xhr.setRequestHeader('Content-Type', 'application/x-www-form-urlencoded');
        xhr.setRequestHeader('X-Requested-With', 'XMLHttpRequest');
        xhr.send('volume=' + val + '&card=' + currentCard + '&control=' + currentControl);
    };

    setTimeout(function() {
        var btn = document.getElementById('refresh_snd_btn');
        if(btn) { btn.click(); }
    }, 500);
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

-- ===== 定时音量调整（每组带独立开关，关闭时自动折叠隐藏） =====
for i = 1, 4 do
    -- 独立启用开关
    local enable_opt = s:taboption("playback", Flag, "enable_time" .. i, 
        translate("启用定时音量 " .. i))
    enable_opt.default = "0"
    enable_opt.rmempty = false
    enable_opt.description = translate("开启后才生效，关闭时下方时间与音量输入框会自动折叠隐藏。")

    -- 时间输入框，依赖开关
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

    -- 音量输入框，同样依赖开关
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
    local new_lines = {}
    for i = 1, 4 do
        -- 只有开关为 1 时才生成 cron 任务
        local enabled = uci:get(cfg, section, "enable_time" .. i) or "0"
        if enabled == "1" then
            local t = uci:get(cfg, section, "time" .. i) or ""
            local v = uci:get(cfg, section, "volume" .. i) or ""
            if t ~= "" and v ~= "" then
                local hh, mm = t:match("^(%d?%d):(%d%d)$")
                if hh and mm then
                    table.insert(new_lines, string.format(
                        "%d %d * * * curl -s -X PUT 'http://127.0.0.1:3689/api/player/volume?volume=%s' >/dev/null 2>&1",
                        tonumber(mm), tonumber(hh), v))
                end
            end
        end
    end
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


-- ===== 独立音量控制（softvol）配置开关 =====
local softvol_enable = s:taboption("advanced", Flag, "softvol_enable",
    translate("启用独立音量控制 (Softvol)"),
    translate("开启后，会为 OwnTone 创建独立的软件混音器，音量不受 AirPlay 和 DLNA 影响。"))

softvol_enable.default = "0"
softvol_enable.rmempty = false

-- 应用按钮
local apply_softvol = s:taboption("advanced", Button, "apply_softvol",
    translate("应用 Softvol 配置"))
apply_softvol.inputstyle = "apply"
function apply_softvol.write(self, section)
    local uci = self.map.uci
    local cfg = self.map.config
    uci:commit(cfg)

    -- 只有当用户开启了 softvol 时才去生成配置
    local enabled = uci:get(cfg, section, "softvol_enable") or "0"
    if enabled == "1" then
        -- 调用后端 API 写入 /etc/asound.conf
        luci.sys.exec("curl -s -X POST http://127.0.0.1/cgi-bin/luci/admin/services/owntone/write_asound >/dev/null 2>&1")
    else
        -- 关闭时恢复最简单的默认配置（仅 dmixer，不含 softvol）
        local sys = require "luci.sys"
        local fs = require "nixio.fs"
        local cards = sys.exec("cat /proc/asound/cards 2>/dev/null")
        local _, name = cards:match("(%d+) %[([^%]]+)%]")
        name = name and name:gsub("%s+$", "") or "Headset"

        local simple_conf = string.format([[
defaults.pcm.dmix.rate 44100
defaults.pcm.dmix.format S16_LE

pcm.!default {
    type plug
    slave.pcm "dmixer"
}

pcm.dmixer {
    type dmix
    ipc_key 1024
    ipc_perm 0666
    slave {
        pcm "hw:%s,0"
        period_time 0
        period_size 1024
        buffer_size 8192
        rate 44100
        format S16_LE
    }
    bindings { 0 0 1 1 }
}
ctl.dmixer {
    type hw
    card %s
}
]], name, name)
        fs.writefile("/etc/asound.conf", simple_conf)
        sys.exec("/etc/init.d/owntone restart >/dev/null 2>&1")
        sys.exec("/etc/init.d/shairport-sync restart >/dev/null 2>&1")
        sys.exec("/etc/init.d/gmediarender restart >/dev/null 2>&1")
    end
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
