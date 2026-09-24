module("luci.controller.owntone", package.seeall)

function index()
	if not nixio.fs.access("/etc/config/owntone") then
		return
	end

	entry({"admin", "nas", "owntone"}, cbi("owntone"), _("Music Remote Center")).dependent = true
	entry({"admin", "nas", "owntone", "status"}, call("act_status")).leaf = true
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
