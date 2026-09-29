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
        -- 如果 asound.conf 里用的是数字编号
        if name:match("^%d+$") then
            card_num = name
            local num, cname = cards:match("(" .. name .. ") %[([^%]]+)%]")
            if cname then card_name = cname:gsub("%s+$", "") end
        else
            -- 如果用的是声卡名
            for num, cname in cards:gmatch("(%d+) %[([^%]]+)%]") do
                if cname:gsub("%s+$", "") == name then
                    card_num = num
                    card_name = cname:gsub("%s+$", "")
                    break
                end
            end
        end
    end
    -- 找不到就退回第一块声卡
    if not card_name or card_name == "" then
        local num, cname = cards:match("(%d+) %[([^%]]+)%]")
        if num then card_num = num; card_name = cname:gsub("%s+$", "") end
    end

    -- 找控制项
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

    -- 读取实际插着的声卡（第一块）
    local cards = sys.exec("cat /proc/asound/cards 2>/dev/null")
    local card_num, card_name = "0", "Headset"
    local num, name = cards:match("(%d+) %[([^%]]+)%]")
    if num then
        card_num = num
        card_name = name:gsub("%s+$", "")
    end

    -- 找控制项
    local control_name = "Headphone"
    local scontrols = sys.exec("amixer -c " .. card_num .. " scontrols 2>/dev/null")
    if scontrols:match("'Headphone'") then control_name = "Headphone"
    elseif scontrols:match("'Master'") then control_name = "Master"
    elseif scontrols:match("'PCM'") then control_name = "PCM"
    else
        local first = scontrols:match("'([^']+)'")
        if first then control_name = first end
    end

    -- 用声卡名写配置，防止编号变动后找不到
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

    -- 唤醒 softvol 并重启服务
    sys.exec("aplay -D softvol /dev/zero -d 1 >/dev/null 2>&1")
    sys.exec("/etc/init.d/owntone restart >/dev/null 2>&1")
    sys.exec("/etc/init.d/shairport-sync restart >/dev/null 2>&1")
    sys.exec("/etc/init.d/gmediarender restart >/dev/null 2>&1")

    -- 读取当前音量返回给前端
    local vol_out = sys.exec("amixer -c " .. card_num .. " sget '" .. control_name .. "' 2>/dev/null")
    local vol = vol_out:match("%[(%d+)%%%]") or "0"

    luci.http.prepare_content("application/json")
    luci.http.write_json({
        success = true, card = card_num, name = card_name,
        control = control_name, volume = tonumber(vol)
    })
end
