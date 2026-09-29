module("luci.controller.owntone", package.seeall)

function index()
	if not nixio.fs.access("/etc/config/owntone") then
		return
	end

	entry({"admin", "nas", "owntone"}, cbi("owntone"), _("Music Remote Center")).dependent = true
	entry({"admin", "nas", "owntone", "status"}, call("act_status")).leaf = true
    -- 新增的路由
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

		-- 请求 /api/player 获取播放状态
		local player_json = luci.sys.exec(string.format(
			"curl -s --connect-timeout 2 http://127.0.0.1:%s/api/player 2>/dev/null", port))

		if player_json and #player_json > 0 then
			-- 纯字符串匹配解析，不依赖 luci.jsonc
			local st = player_json:match('"state"%s*:%s*"([^"]+)"')
			if st then e.state = st end

			local item_id = player_json:match('"item_id"%s*:%s*(%d+)')

			-- 仅在播放/暂停状态且有曲目时，查询当前曲目详情
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

		-- 调试日志（问题解决后可以删除这整块）
		local log = io.open("/tmp/owntone_debug.log", "w")
		if log then
			log:write("state=" .. tostring(e.state) .. " title=" .. tostring(e.title) .. "\n")
			log:write("raw player_json:\n" .. tostring(player_json):sub(1, 600) .. "\n")
			log:close()
		end
	end

	luci.http.prepare_content("application/json")
	luci.http.write_json(e)
end
-- 获取当前声卡信息（供前端滑块初始化）
function action_get_soundcard_info()
    local sys = require "luci.sys"
    local card_num, card_name, control_name = "0", "Headset", "Headphone"
    
    local cards = sys.exec("cat /proc/asound/cards 2>/dev/null")
    local num, name = cards:match("(%d+) %[([^%]]+)%]")
    if num then
        card_num = num
        card_name = name:gsub("%s+$", "")
    end
    
    -- 优先寻找 Headphone, Master, PCM，否则取第一个
    local scontrols = sys.exec("amixer -c " .. card_num .. " scontrols 2>/dev/null")
    if scontrols:match("'Headphone'") then control_name = "Headphone"
    elseif scontrols:match("'Master'") then control_name = "Master"
    elseif scontrols:match("'PCM'") then control_name = "PCM"
    else
        local first = scontrols:match("'([^']+)'")
        if first then control_name = first end
    end
    
    -- 获取当前音量
    local vol_out = sys.exec("amixer -c " .. card_num .. " sget '" .. control_name .. "' 2>/dev/null")
    local vol = vol_out:match("%[(%d+)%%%]") or "80"
    
    luci.http.prepare_content("application/json")
    luci.http.write_json({ success = true, card = card_num, name = card_name, control = control_name, volume = tonumber(vol) })
end

-- 执行音量调节
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

-- 刷新并重写 ALSA 配置
function action_refresh_soundcard()
    local sys = require "luci.sys"
    local fs = require "nixio.fs"
    
    local card_num, card_name, control_name = "0", "Headset", "Headphone"
    local cards = sys.exec("cat /proc/asound/cards 2>/dev/null")
    local num, name = cards:match("(%d+) %[([^%]]+)%]")
    if num then
        card_num = num
        card_name = name:gsub("%s+$", "")
    end
    
    local scontrols = sys.exec("amixer -c " .. card_num .. " scontrols 2>/dev/null")
    if scontrols:match("'Headphone'") then control_name = "Headphone"
    elseif scontrols:match("'Master'") then control_name = "Master"
    elseif scontrols:match("'PCM'") then control_name = "PCM"
    else
        local first = scontrols:match("'([^']+)'")
        if first then control_name = first end
    end

    -- 写入标准 /etc/asound.conf（使用声卡名字代替数字编号，防止再次变动）
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
    
    -- 唤醒 softvol 并重启所有服务
    sys.exec("aplay -D softvol /dev/zero -d 1 >/dev/null 2>&1")
    sys.exec("/etc/init.d/owntone restart >/dev/null 2>&1")
    sys.exec("/etc/init.d/shairport-sync restart >/dev/null 2>&1")
    sys.exec("/etc/init.d/gmediarender restart >/dev/null 2>&1")
    
    luci.http.prepare_content("application/json")
    luci.http.write_json({ success = true, card = card_num, name = card_name, control = control_name })
end
