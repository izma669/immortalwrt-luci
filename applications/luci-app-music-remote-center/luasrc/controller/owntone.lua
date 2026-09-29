module("luci.controller.owntone", package.seeall)

function index()
    if not nixio.fs.access("/etc/config/owntone") then
        return
    end

    entry({"admin", "nas", "owntone"}, cbi("owntone"), _("Music Remote Center")).dependent = true
    entry({"admin", "nas", "owntone", "status"}, call("act_status")).leaf = true
    entry({"admin", "nas", "owntone", "set_volume"}, call("action_set_volume")).leaf = true
    entry({"admin", "nas", "owntone", "get_soundcard_info"}, call("action_get_soundcard_info")).leaf = true
    entry({"admin", "nas", "owntone", "refresh_soundcard"}, call("action_refresh_soundcard")).leaf = true
    entry({"admin", "nas", "owntone", "apply_schedule"}, call("action_apply_schedule")).leaf = true
    entry({"admin", "nas", "owntone", "restart_service"}, call("action_restart_service")).leaf = true
end

function act_status()
    local e = { running = false, state = "unknown", title = "", artist = "", album = "" }
    e.running = luci.sys.call("pgrep owntone >/dev/null") == 0

    if e.running then
        local uci = require "luci.model.uci".cursor()
        local port = uci:get("owntone", "owntone", "port") or "3689"
        local player_json = luci.sys.exec(string.format(
            "curl -s --connect-timeout 2 http://127.0.0.1:%s/api/player 2>/dev/null", port))

        if player_json and #player_json > 0 then
            local st = player_json:match('"state"%s*:%s*"([^"]+)"')
            if st then e.state = st end
            local item_id = player_json:match('"item_id"%s*:%s*(%d+)')

            if (e.state == "play" or e.state == "pause") and item_id then
                local q_json = luci.sys.exec(string.format(
                    "curl -s --connect-timeout 2 \"http://127.0.0.1:%s/api/queue?id=now_playing\" 2>/dev/null", port))
                if q_json and #q_json > 0 then
                    e.title  = q_json:match('"title"%s*:%s*"([^"]*)"')  or ""
                    e.artist = q_json:match('"artist"%s*:%s*"([^"]*)"') or ""
                    e.album  = q_json:match('"album"%s*:%s*"([^"]*)"')  or ""
                end
            end
        end
    end

    luci.http.prepare_content("application/json")
    luci.http.write_json(e)
end

-- 从 /etc/asound.conf 里解析出当前配置的声卡名
local function parse_asound_card()
    local fs = require "nixio.fs"
    if not fs.access("/etc/asound.conf") then return nil end
    local data = fs.readfile("/etc/asound.conf") or ""
    local name = data:match('pcm%s+"hw:([^,]+),')
    return name
end

-- 根据声卡名找到编号和音量控制项
local function resolve_card(name)
    local sys = require "luci.sys"
    local card_num, card_name, control_name = "0", "Headset", "Headphone"
    local cards = sys.exec("cat /proc/asound/cards 2>/dev/null")

    if name and name ~= "" then
        if name:match("^%d+$") then
            card_num = name
            local num, cname = cards:match("(" .. name .. ") %[([^%]]+)%]")
            if cname then card_name = cname:gsub("%s+$", "") end
        else
            for num, cname in cards:gmatch("(%d+) %[([^%]]+)%]") do
                if cname:gsub("%s+$", "") == name then
                    card_num = num
                    card_name = cname:gsub("%s+$", "")
                    break
                end
            end
        end
    end
    if not card_name or card_name == "" then
        local num, cname = cards:match("(%d+) %[([^%]]+)%]")
        if num then card_num = num; card_name = cname:gsub("%s+$", "") end
    end

    local scontrols = sys.exec("amixer -c " .. card_num .. " scontrols 2>/dev/null")
    if scontrols:match("'Headphone'") then control_name = "Headphone"
    elseif scontrols:match("'Master'") then control_name = "Master"
    elseif scontrols:match("'PCM'") then control_name = "PCM"
    else
        local first = scontrols:match("'([^']+)'")
        if first then control_name = first end
    end
    return card_num, card_name, control_name
end

-- 读取当前声卡信息和音量（不写配置，不重启）
function action_get_soundcard_info()
    local sys = require "luci.sys"
    local card_name = parse_asound_card()
    local card_num, cname, control = resolve_card(card_name)
    local vol_out = sys.exec("amixer -c " .. card_num .. " sget '" .. control .. "' 2>/dev/null")
    local vol = vol_out:match("%[(%d+)%%%]") or "80"
    luci.http.prepare_content("application/json")
    luci.http.write_json({
        success = true, card = card_num, name = cname,
        control = control, volume = tonumber(vol)
    })
end

-- 调整音量（只调音量）
function action_set_volume()
    local vol = luci.http.formvalue("volume")
    local card = luci.http.formvalue("card") or "0"
    local control = luci.http.formvalue("control") or "Headphone"
    if vol and vol:match("^%d+$") then
        luci.sys.exec("amixer -c " .. card .. " sset '" .. control .. "' " .. vol .. "% unmute >/dev/null 2>&1")
    end
    luci.http.prepare_content("application/json")
    luci.http.write_json({ success = true })
end

-- 手动刷新：检测新声卡 → 重写 /etc/asound.conf → 重启服务
function action_refresh_soundcard()
    local sys = require "luci.sys"
    local fs = require "nixio.fs"

    local cards = sys.exec("cat /proc/asound/cards 2>/dev/null")
    local card_num, card_name = "0", "Headset"
    local num, name = cards:match("(%d+) %[([^%]]+)%]")
    if num then
        card_num = num
        card_name = name:gsub("%s+$", "")
    end

    local control_name = "Headphone"
    local scontrols = sys.exec("amixer -c " .. card_num .. " scontrols 2>/dev/null")
    if scontrols:match("'Headphone'") then control_name = "Headphone"
    elseif scontrols:match("'Master'") then control_name = "Master"
    elseif scontrols:match("'PCM'") then control_name = "PCM"
    else
        local first = scontrols:match("'([^']+)'")
        if first then control_name = first end
    end

    local new_conf = string.format([[
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

pcm.softvol {
    type softvol
    slave.pcm "plug:dmixer"
    control {
        name "Softvol"
        card %s
    }
}
]], card_name, card_name, card_name)

    fs.writefile("/etc/asound.conf", new_conf)

    sys.exec("aplay -D softvol /dev/zero -d 1 >/dev/null 2>&1")
    sys.exec("/etc/init.d/owntone restart >/dev/null 2>&1")
    sys.exec("/etc/init.d/shairport-sync restart >/dev/null 2>&1")
    sys.exec("/etc/init.d/gmediarender restart >/dev/null 2>&1")

    local vol_out = sys.exec("amixer -c " .. card_num .. " sget '" .. control_name .. "' 2>/dev/null")
    local vol = vol_out:match("%[(%d+)%%%]") or "0"

    luci.http.prepare_content("application/json")
    luci.http.write_json({
        success = true, card = card_num, name = card_name,
        control = control_name, volume = tonumber(vol)
    })
end

-- 独立重启 OwnTone 服务（供 HTML 按钮调用）
function action_restart_service()
    luci.sys.call("/etc/init.d/owntone restart >/dev/null 2>&1")
    luci.http.prepare_content("application/json")
    luci.http.write_json({ success = true })
end

-- 应用定时音量计划（同时写 UCI 和 crontab）
function action_apply_schedule()
    local uci = require "luci.model.uci".cursor()
    local sys = require "luci.sys"
    local fs = require "nixio.fs"

    -- 收集前端传来的所有参数
    local params = {}
    for i = 1, 4 do
        params["enable_time" .. i] = luci.http.formvalue("enable_time" .. i) or "0"
        params["time" .. i]        = luci.http.formvalue("time" .. i) or ""
        params["target" .. i]      = luci.http.formvalue("target" .. i) or "softvol"
        params["volume" .. i]      = luci.http.formvalue("volume" .. i) or ""
    end

    -- 保存到 UCI，让下次打开页面还能看到
    for k, v in pairs(params) do
        uci:set("owntone", "owntone", k, v)
    end
    uci:commit("owntone")

    -- 解析当前物理声卡编号和控制项
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

    -- 生成新的 cron 任务
    local new_lines = {}
    for i = 1, 4 do
        if params["enable_time" .. i] == "1" then
            local t = params["time" .. i]
            local v = params["volume" .. i]
            local target = params["target" .. i]
            if t ~= "" and v ~= "" then
                local hh, mm = t:match("^(%d?%d):(%d%d)$")
                if hh and mm then
                    if target == "hw" then
                        table.insert(new_lines, string.format(
                            "%d %d * * * amixer -c %s sset '%s' %s%% unmute >/dev/null 2>&1",
                            tonumber(mm), tonumber(hh), card_num, control_name, v))
                    else
                        table.insert(new_lines, string.format(
                            "%d %d * * * curl -s -X PUT 'http://127.0.0.1:3689/api/player/volume?volume=%s' >/dev/null 2>&1",
                            tonumber(mm), tonumber(hh), v))
                    end
                end
            end
        end
    end

    -- 清理旧任务，写入新任务
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
    for _, l in ipairs(new_lines) do table.insert(kept, l) end
    f = io.open(crontab, "w")
    if f then
        f:write(table.concat(kept, "\n") .. "\n")
        f:close()
    end
    sys.call("/etc/init.d/cron restart >/dev/null 2>&1")

    luci.http.prepare_content("application/json")
    luci.http.write_json({ success = true, count = #new_lines })
end
