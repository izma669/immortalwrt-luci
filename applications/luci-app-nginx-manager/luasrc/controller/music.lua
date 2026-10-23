-- 音乐中心（Music Center）公开接口
--
-- 目标：让 888 端口的静态页面在不登录 LuCI 的情况下，读取并控制本机的
--       OwnTone / GMediaRender / AirPlay(shairport-sync) 三个音乐服务。
--
-- 路径放在 /cgi-bin/luci/music/*，不带 admin 前缀，因此不需要 LuCI 会话；
-- 安全边界完全由本文件负责：
--   1) 只接受内网来源（IPv4 私有地址 / 回环 / IPv6；公网 IPv4 一律拒绝）；
--   2) 写操作必须是 POST；带 Origin 的浏览器请求必须与 Host 同源，
--      防止别的网页跨站偷偷控制家里的音箱；
--   3) 所有 shell 参数都做白名单或转义。
--
-- 注意：888 端口本身由 /etc/nginx/conf.d/music.conf 提供，本文件只负责 API。

module("luci.controller.music", package.seeall)

local http = require "luci.http"
local jsonc = require "luci.jsonc"
local sys = require "luci.sys"
local nixio = require "nixio"
local fs = require "nixio.fs"
local uci = require "luci.model.uci".cursor()

local SND_CACHE = "/tmp/music-center-sndcard"
local GMR_LAST_DL = "/tmp/gmediarender_last_dl.txt"
local OWNTONE_MUTE_STATE = "/tmp/music-center-owntone-mute"

function index()
    entry({"music", "status"}, call("action_status")).leaf = true
    entry({"music", "control"}, post("action_control")).leaf = true
    entry({"music", "volume"}, post("action_volume")).leaf = true
    entry({"music", "service"}, post("action_service")).leaf = true
    entry({"music", "download"}, post("action_download")).leaf = true
    entry({"music", "download_log"}, call("action_download_log")).leaf = true
    entry({"music", "cover"}, call("action_cover")).leaf = true
end

-------------------------------------------------------------------------------
-- 小工具
-------------------------------------------------------------------------------

local function trim(s)
    return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function shell_quote(s)
    return "'" .. tostring(s or ""):gsub("'", "'\\''") .. "'"
end

local function respond(ok, err)
    http.prepare_content("application/json")
    http.write(jsonc.stringify({ ok = ok and true or false, error = err or nil }))
end

local function json_error(code, msg)
    http.status(code)
    http.prepare_content("application/json")
    http.write(jsonc.stringify({ ok = false, error = msg }))
end

local function require_post()
    if http.getenv("REQUEST_METHOD") ~= "POST" then
        http.status(405)
        http.header("Allow", "POST")
        http.prepare_content("application/json")
        http.write('{"ok":false,"error":"请使用 POST 请求"}')
        return false
    end
    return true
end

local function uci_get(cfg, typ, opt, default)
    local v = uci:get_first(cfg, typ, opt)
    if v == nil or v == "" then return default end
    return tostring(v)
end

local function plugin_enabled(cfg, typ)
    local v = tostring(uci_get(cfg, typ, "enabled", "0")):lower()
    return v == "1" or v == "true" or v == "yes" or v == "on"
end

local function process_running(name)
    return sys.call("pidof " .. name .. " >/dev/null 2>&1") == 0
end

local function installed(bin, cfg)
    return (bin and fs.access(bin)) or (cfg and fs.access(cfg)) or false
end

-- 把 UCI 里某个匿名 section 的 enabled 选项写成 value（不重启服务）
local function set_plugin_enabled(cfg, typ, value)
    local changed = false
    uci:foreach(cfg, typ, function(s)
        uci:set(cfg, s[".name"], "enabled", value)
        changed = true
        return false
    end)
    if changed then uci:commit(cfg) end
    return changed
end

-------------------------------------------------------------------------------
-- 来源校验
--
-- 不要求密码，所以必须至少做到“内网可用、外网不可用、跨站不可写”。
-- IPv6 不在这里按私网前缀卡死：很多家庭宽带给内网设备分配的是全球单播地址，
-- 真正的外网边界交给 OpenWrt 防火墙（WAN 默认 REJECT）。公网 IPv4 直接拒绝。
-------------------------------------------------------------------------------

local function ip_is_private(ip)
    if not ip or ip == "" then return false end
    local mapped = ip:match("^::ffff:(%d+%.%d+%.%d+%.%d+)$")
    if mapped then ip = mapped end

    if ip == "127.0.0.1" or ip == "::1" then return true end
    if ip:match("^10%.") or ip:match("^192%.168%.") or ip:match("^169%.254%.") then return true end

    local second = tonumber(ip:match("^172%.(%d+)%."))
    if second and second >= 16 and second <= 31 then return true end

    -- 100.64.0.0/10（运营商级 NAT / 部分随身路由）
    local cgnat = tonumber(ip:match("^100%.(%d+)%."))
    if cgnat and cgnat >= 64 and cgnat <= 127 then return true end

    -- IPv6：回环、ULA、链路本地，以及内网常见的全球单播，均放行
    if ip:find(":", 1, true) then
        if ip:match("^[fF][cCdD]") or ip:match("^[fF][eE][89abAB]") then return true end
        return true
    end
    return false
end

-- nginx 会把真实客户端地址放到 X-Real-IP / X-Forwarded-For；
-- 只有请求确实来自本机反向代理时才信任，避免直接访问 80 时伪造。
local function client_ip()
    local raddr = http.getenv("REMOTE_ADDR") or ""
    if raddr == "127.0.0.1" or raddr == "::1" then
        local real = http.getenv("HTTP_X_REAL_IP") or ""
        if real == "" then
            local xff = http.getenv("HTTP_X_FORWARDED_FOR") or ""
            local last
            for ip in xff:gmatch("[^,%s]+") do last = ip end
            real = last or ""
        end
        if real ~= "" then return real end
    end
    return raddr
end

local function normalize_host(host)
    host = (host or ""):lower()
    local bracketed = host:match("^%[([^%]]+)%]")
    if bracketed then return bracketed end
    local _, colons = host:gsub(":", "")
    if colons <= 1 then host = host:gsub(":%d+$", "") end
    return host
end

local function host_is_lan(host)
    if not host or host == "" then return false end
    host = normalize_host(host)
    if host == "localhost" or host == "::1" then return true end
    if host:match("^%d+%.%d+%.%d+%.%d+$") then return ip_is_private(host) end
    if host:find(":", 1, true) then return ip_is_private(host) end
    if host:match("^[^.]+$") then return true end
    return host:match("%.local$") ~= nil or host:match("%.lan$") ~= nil
        or host:match("%.home$") ~= nil or host:match("%.internal$") ~= nil
        or host:match("%.home%.arpa$") ~= nil
end

local function guard(write)
    if not ip_is_private(client_ip()) then
        json_error(403, "音乐中心仅限局域网访问")
        return false
    end

    if write then
        local origin = http.getenv("HTTP_ORIGIN") or ""
        if origin ~= "" then
            local ohost = origin:match("^https?://([^/]+)$")
            local hhost = http.getenv("HTTP_HOST") or ""
            if not ohost or not host_is_lan(ohost) or not host_is_lan(hhost)
                or normalize_host(ohost) ~= normalize_host(hhost) then
                json_error(403, "拒绝跨站控制请求")
                return false
            end
        end
    end
    return true
end

-------------------------------------------------------------------------------
-- 网络
-------------------------------------------------------------------------------

local _lan_ip
local function lan_ip()
    if _lan_ip then return _lan_ip end
    local ip = uci:get("network", "lan", "ipaddr")
    if ip and ip:match("^%d+%.%d+%.%d+%.%d+$") then
        _lan_ip = ip
        return ip
    end
    local ok, ifs = pcall(nixio.getifaddrs)
    if ok and type(ifs) == "table" then
        for _, ifa in ipairs(ifs) do
            if ifa.name == "br-lan" and ifa.family == "inet"
                and ifa.addr and ifa.addr ~= "" then
                _lan_ip = ifa.addr
                return ifa.addr
            end
        end
    end
    _lan_ip = "127.0.0.1"
    return _lan_ip
end

-- 只取 Host 里的主机部分：nginx 传 $host 时本来就不带端口，
-- 直连 LuCI 80 时可能带 :80，这里统一剥掉；IPv6 的方括号要保留。
local function host_only()
    local h = http.getenv("HTTP_HOST") or ""
    if h == "" then return "" end
    local bracketed = h:match("^(%[[^%]]+%])")
    if bracketed then return bracketed end
    return (h:gsub(":%d+$", ""))
end

local function dechunk(body)
    local out, pos = {}, 1
    while true do
        local e = body:find("\r\n", pos, true)
        if not e then break end
        local size = tonumber(body:sub(pos, e - 1):gsub(";.*$", ""), 16)
        if not size or size == 0 then break end
        out[#out + 1] = body:sub(e + 2, e + 1 + size)
        pos = e + 2 + size + 2
    end
    return table.concat(out)
end

-- 极简 HTTP 客户端：只访问 127.0.0.1/局域网，不处理重定向、Cookie。
-- 返回 body, status_code, err
local function http_send(method, host, port, path, body, ctype, extra_headers, timeout)
    local sock = nixio.socket("inet", "stream")
    if not sock then return nil, nil, "socket" end
    local t = timeout or 1
    pcall(function() sock:setopt("socket", "rcvtimeo", t) end)
    pcall(function() sock:setopt("socket", "sndtimeo", t) end)

    local ok = sock:connect(host, port)
    if not ok then
        sock:close()
        return nil, nil, "connect"
    end

    local req = method .. " " .. path .. " HTTP/1.1\r\n"
        .. "Host: " .. host .. ":" .. tostring(port) .. "\r\n"
        .. "User-Agent: music-center/1.0\r\n"
        .. "Accept: */*\r\n"
        .. "Connection: close\r\n"
    if ctype then req = req .. "Content-Type: " .. ctype .. "\r\n" end
    if extra_headers then req = req .. extra_headers end
    if body then
        req = req .. "Content-Length: " .. tostring(#body) .. "\r\n\r\n" .. body
    else
        req = req .. "Content-Length: 0\r\n\r\n"
    end

    if not sock:send(req) then
        sock:close()
        return nil, nil, "send"
    end

    local chunks, total = {}, 0
    while true do
        local data = sock:recv(8192)
        if not data or data == "" then break end
        chunks[#chunks + 1] = data
        total = total + #data
        if total > 512 * 1024 then break end
    end
    sock:close()

    local resp = table.concat(chunks)
    local head, payload = resp:match("^(.-)\r\n\r\n(.*)$")
    if not head then return nil, nil, "response" end
    local code = tonumber(head:match("^HTTP/%d%.%d%s+(%d+)"))
    if head:lower():find("transfer%-encoding:%s*chunked") then
        payload = dechunk(payload or "")
    end
    return payload or "", code
end

local function http_get(host, port, path, timeout)
    local body, code = http_send("GET", host, port, path, nil, nil, nil, timeout)
    if not body or not code or code < 200 or code >= 300 then return nil end
    return body
end

local function http_put(host, port, path, timeout)
    local _, code = http_send("PUT", host, port, path, nil, nil, nil, timeout)
    return code == 200 or code == 204
end

-------------------------------------------------------------------------------
-- 物理声卡音量
-------------------------------------------------------------------------------

local function read_snd_cache()
    local st = fs.stat(SND_CACHE)
    if not st or not st.mtime then return nil end
    if os.time() - st.mtime > 60 then return nil end
    local raw = fs.readfile(SND_CACHE) or ""
    -- 文件末尾带换行，第三个字段用 + 而不是 *，否则 $ 匹配不到
    local card, name, control = raw:match("^([^\n]*)\n([^\n]*)\n([^\n]+)")
    if card and card ~= "" and control and control ~= "" then
        return card, name or "", control
    end
    return nil
end

local function write_snd_cache(card, name, control)
    local f = io.open(SND_CACHE, "w")
    if f then
        f:write(tostring(card), "\n", tostring(name or ""), "\n", tostring(control), "\n")
        f:close()
    end
end

local function resolve_soundcard()
    local card, name, control = read_snd_cache()

    if not card then
        local asound = ""
        if fs.access("/etc/asound.conf") then
            asound = fs.readfile("/etc/asound.conf") or ""
        end
        local want = asound:match('pcm%s+"hw:([^,]+),')

        local cards = fs.readfile("/proc/asound/cards") or ""
        local by_name, first_num, first_name = {}, nil, nil
        for num, cname in cards:gmatch("(%d+)%s+%[([^%]]+)%]") do
            cname = trim(cname)
            by_name[cname] = num
            if not first_num then
                first_num, first_name = num, cname
            end
        end

        if want and want:match("^%d+$") then
            card = want
        elseif want and by_name[want] then
            card = by_name[want]
        else
            card = first_num or "0"
        end

        for num, cname in cards:gmatch("(%d+)%s+%[([^%]]+)%]") do
            if num == card then name = trim(cname); break end
        end
        if not name or name == "" then name = first_name or "" end

        local scontrols = sys.exec("amixer -c " .. tostring(card) .. " scontrols 2>/dev/null") or ""
        if scontrols:match("'Headphone'") then control = "Headphone"
        elseif scontrols:match("'Master'") then control = "Master"
        elseif scontrols:match("'PCM'") then control = "PCM"
        elseif scontrols:match("'Speaker'") then control = "Speaker"
        else control = scontrols:match("'([^']+)'") end
        control = control or "Master"

        write_snd_cache(card, name, control)
    end

    local sget = sys.exec("amixer -c " .. tostring(card) .. " sget "
        .. shell_quote(control) .. " 2>/dev/null") or ""
    local volume = tonumber(sget:match("%[(%d+)%%%]")) or 0
    local muted = sget:match("%[off%]") ~= nil

    return {
        available = sget ~= "",
        card = tostring(card),
        name = name or "",
        control = control,
        volume = volume,
        muted = muted,
    }
end

local function set_physical_volume(action, value)
    local info = resolve_soundcard()
    if not info.available then return false, "没有找到可用的声卡混音控制" end

    local cmd
    if action == "mute" then
        cmd = "amixer -c " .. info.card .. " sset " .. shell_quote(info.control) .. " mute"
    elseif action == "unmute" then
        cmd = "amixer -c " .. info.card .. " sset " .. shell_quote(info.control) .. " unmute"
    else
        local v = math.max(0, math.min(100, tonumber(value) or 0))
        cmd = "amixer -c " .. info.card .. " sset " .. shell_quote(info.control)
            .. " " .. tostring(math.floor(v)) .. "% unmute"
    end
    local rc = sys.call(cmd .. " >/dev/null 2>&1")
    if rc ~= 0 then return false, "amixer 执行失败" end
    return true
end

-------------------------------------------------------------------------------
-- OwnTone
-------------------------------------------------------------------------------

local function owntone_port()
    return tonumber(uci_get("owntone", "owntone", "port", "3689")) or 3689
end

local function absolute_art(url, port)
    if not url or url == "" then return "" end
    if url:match("^https?://") then return url end
    if url:sub(1, 1) ~= "/" then url = "/" .. url end
    local h = host_only()
    if h == "" then h = "127.0.0.1" end
    return string.format("http://%s:%d%s", h, port, url)
end

local function owntone_status()
    local port = owntone_port()
    local st = {
        installed = installed("/usr/sbin/owntone", "/etc/config/owntone"),
        enabled = plugin_enabled("owntone", "owntone"),
        running = process_running("owntone"),
        state = "stop",
        playing = false,
        title = "", artist = "", album = "", art = "",
        position = 0, duration = 0, volume = 0,
        format = "", bitrate = 0, samplerate = 0,
        muted = false, mute_volume = 0,
        name = tostring(uci:get("owntone", "owntone", "player_name") or ""),
        port = port,
    }
    if not st.running then return st end

    local body = http_get("127.0.0.1", port, "/api/player", 1)
    if not body then
        st.error = "OwnTone API 无响应"
        return st
    end

    local ok, p = pcall(jsonc.parse, body)
    if not ok or type(p) ~= "table" then
        st.error = "OwnTone API 返回了无法解析的数据"
        return st
    end

    st.state = tostring(p.state or "stop")
    st.playing = (st.state == "play")
    st.volume = tonumber(p.volume) or 0
    local mute_saved = tonumber(fs.readfile(OWNTONE_MUTE_STATE) or "")
    if mute_saved and mute_saved > 0 and st.volume <= 0 then
        st.muted = true
        st.mute_volume = mute_saved
    elseif mute_saved then
        fs.unlink(OWNTONE_MUTE_STATE)
    end
    st.shuffle = (p.shuffle == true)
    st["repeat"] = tostring(p["repeat"] or "off")
    -- OwnTone 的 /api/player 用 item_progress_ms 表示当前进度（position_ms 只用于 seek 参数）
    st.position = (tonumber(p.item_progress_ms) or tonumber(p.position_ms) or 0) / 1000
    st.duration = (tonumber(p.item_length_ms) or 0) / 1000
    local item_id = tonumber(p.item_id)

    if (st.state == "play" or st.state == "pause") and item_id and item_id > 0 then
        local q = http_get("127.0.0.1", port, "/api/queue?id=now_playing", 1)
        if q then
            local qok, qd = pcall(jsonc.parse, q)
            if qok and type(qd) == "table" then
                local item = qd.items and qd.items[1] or qd
                if type(item) == "table" then
                    st.title = tostring(item.title or item.name or "")
                    st.artist = tostring(item.artist or "")
                    st.album = tostring(item.album or "")
                    if st.duration <= 0 then
                        st.duration = (tonumber(item.length_ms) or 0) / 1000
                    end
                    local fmt = tostring(item.codec or item.format or "")
                    if fmt == "" then
                        fmt = tostring(item.path or ""):match("%.([%w]+)$") or ""
                    end
                    st.format = fmt:upper()
                    st.bitrate = tonumber(item.bitrate) or 0
                    st.samplerate = tonumber(item.samplerate) or 0
                    st.art = absolute_art(tostring(item.artwork_url or ""), port)
                end
            end
        end
    end

    return st
end

local function owntone_control(action, value)
    local port = owntone_port()

    if action == "seek" then
        local sec = tonumber(value) or 0
        if sec < 0 then sec = 0 end
        local ok = http_put("127.0.0.1", port,
            "/api/player/seek?position_ms=" .. tostring(math.floor(sec * 1000)), 2)
        return ok, (not ok) and "OwnTone 不支持跳转或接口无响应" or nil
    end

    if action == "shuffle" then
        local state = (value == "true" or value == "1" or value == "on") and "true" or "false"
        local ok = http_put("127.0.0.1", port,
            "/api/player/shuffle?state=" .. state, 2)
        return ok, (not ok) and "OwnTone 随机播放接口无响应" or nil
    end

    if action == "repeat" then
        local state = tostring(value or "off")
        if state ~= "all" and state ~= "single" then state = "off" end
        local ok = http_put("127.0.0.1", port,
            "/api/player/repeat?state=" .. state, 2)
        return ok, (not ok) and "OwnTone 循环播放接口无响应" or nil
    end

    local map = {
        play = "play",
        pause = "pause",
        toggle = "toggle",
        stop = "stop",
        next = "next",
        previous = "previous",
    }
    local path = map[action]
    if not path then return false, "不支持的播放操作: " .. tostring(action) end

    local ok = http_put("127.0.0.1", port, "/api/player/" .. path, 2)
    return ok, (not ok) and "OwnTone 控制接口无响应" or nil
end

local function owntone_set_volume(value)
    local port = owntone_port()
    local v = math.max(0, math.min(100, tonumber(value) or 0))
    local ok = http_put("127.0.0.1", port,
        "/api/player/volume?volume=" .. tostring(math.floor(v)), 2)
    if ok then fs.unlink(OWNTONE_MUTE_STATE) end
    return ok, (not ok) and "OwnTone 音量接口无响应" or nil
end

local function owntone_mute(action)
    local port = owntone_port()
    local body = http_get("127.0.0.1", port, "/api/player", 1)
    local current = 0
    if body then
        local ok, p = pcall(jsonc.parse, body)
        if ok and type(p) == "table" then current = tonumber(p.volume) or 0 end
    end

    if action == "unmute" then
        local saved = tonumber(fs.readfile(OWNTONE_MUTE_STATE) or "") or current
        if saved <= 0 then saved = 70 end
        local ok = http_put("127.0.0.1", port,
            "/api/player/volume?volume=" .. tostring(math.floor(saved)), 2)
        if ok then fs.unlink(OWNTONE_MUTE_STATE) end
        return ok, (not ok) and "OwnTone 音量接口无响应" or nil
    end

    if current <= 0 then current = 70 end
    local ok = http_put("127.0.0.1", port, "/api/player/volume?volume=0", 2)
    if ok then fs.writefile(OWNTONE_MUTE_STATE, tostring(math.floor(current))) end
    return ok, (not ok) and "OwnTone 音量接口无响应" or nil
end

-------------------------------------------------------------------------------
-- GMediaRender（UPnP AVTransport / RenderingControl）
-------------------------------------------------------------------------------

local function xml_unescape(s)
    s = tostring(s or "")
    s = s:gsub("&lt;", "<"):gsub("&gt;", ">"):gsub("&quot;", '"'):gsub("&apos;", "'")
    return (s:gsub("&amp;", "&"))
end

local function parse_time(t)
    t = trim(t)
    local h, m, s = t:match("^(%d+):(%d+):(%d+)")
    if h then return tonumber(h) * 3600 + tonumber(m) * 60 + tonumber(s) end
    local mm, ss = t:match("^(%d+):(%d+)$")
    if mm then return tonumber(mm) * 60 + tonumber(ss) end
    return tonumber(t) or 0
end

local function upnp_control(ip, port, action, inner)
    local service = "urn:schemas-upnp-org:service:AVTransport:1"
    local path = "/upnp/control/rendertransport1"
    if action == "GetVolume" or action == "SetVolume" then
        service = "urn:schemas-upnp-org:service:RenderingControl:1"
        path = "/upnp/control/rendercontrol1"
    end

    local body = string.format([[
<?xml version="1.0" encoding="utf-8"?>
<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
  <s:Body><u:%s xmlns:u="%s">%s</u:%s></s:Body>
</s:Envelope>]], action, service, inner, action)

    local headers = "SOAPAction: \"" .. service .. "#" .. action .. "\"\r\n"
    local resp, code = http_send("POST", ip, port, path, body,
        "text/xml; charset=\"utf-8\"", headers, 1)
    if not resp or not code then return nil end
    return resp, code
end

-- 旧 gmediarender 控制器用 uclient-fetch/wget 的 --post-file 发 SOAP，
-- 这条路在现场是能切歌的；nixio 裸 HTTP/1.0 POST 在部分 libupnp 版本上
-- 会被拒绝（Next/Previous 返回 500）。GMR 控制统一走这里。
local function upnp_fetch(ip, port, action, inner)
    local service = "urn:schemas-upnp-org:service:AVTransport:1"
    local path = "/upnp/control/rendertransport1"
    if action == "GetVolume" or action == "SetVolume" then
        service = "urn:schemas-upnp-org:service:RenderingControl:1"
        path = "/upnp/control/rendercontrol1"
    end

    local body = string.format([[
<?xml version="1.0" encoding="utf-8"?>
<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
  <s:Body><u:%s xmlns:u="%s">%s</u:%s></s:Body>
</s:Envelope>]], action, service, inner, action)

    local suffix = tostring(os.time()) .. "_" .. tostring(math.random(1000, 9999))
    local tmp_in = "/tmp/music-center-gmr-in-" .. suffix .. ".xml"
    local tmp_out = "/tmp/music-center-gmr-out-" .. suffix .. ".xml"

    local f = io.open(tmp_in, "w")
    if not f then return nil end
    f:write(body)
    f:close()

    local tool = nil
    if sys.call("which uclient-fetch >/dev/null 2>&1") == 0 then
        tool = "uclient-fetch"
    elseif sys.call("which wget >/dev/null 2>&1") == 0 then
        tool = "wget"
    end
    if not tool then
        os.remove(tmp_in)
        return nil
    end

    local cmd
    if tool == "uclient-fetch" then
        cmd = string.format("uclient-fetch -q -O %s -T 2 --post-file='%s' --header='SOAPAction: \"%s#%s\"' --header='Content-Type: text/xml; charset=\"utf-8\"' 'http://%s:%d%s' 2>/dev/null",
            tmp_out, tmp_in, service, action, ip, port, path)
    else
        cmd = string.format("wget -q -O %s -T 2 --post-file='%s' --header='SOAPAction: \"%s#%s\"' --header='Content-Type: text/xml; charset=\"utf-8\"' 'http://%s:%d%s' 2>/dev/null",
            tmp_out, tmp_in, service, action, ip, port, path)
    end
    sys.call(cmd)

    local res = ""
    if fs.access(tmp_out) then
        res = fs.readfile(tmp_out) or ""
    end
    os.remove(tmp_in)
    os.remove(tmp_out)
    if res == "" then return nil end
    return res, 200
end

local function gmr_status(ip, port)
    local st = {
        installed = installed("/usr/bin/gmediarender", "/etc/config/gmediarender"),
        enabled = plugin_enabled("gmediarender", "gmediarender"),
        running = process_running("gmediarender"),
        state = "", playing = false,
        title = "", artist = "", album = "", art = "",
        position = 0, duration = 0, volume = 0,
        format = "", media = "", streamurl = "",
        soundcard = "",
        broadcast = uci_get("gmediarender", "gmediarender", "friendly_name", "GMediaRender"),
        auto_download_triggered = false,
        auto_download_file = "",
    }
    if not st.running then return st end

    local info = upnp_control(ip, port, "GetTransportInfo", "<InstanceID>0</InstanceID>")
    if not info then
        st.error = "GMediaRender UPnP 无响应"
        return st
    end
    st.state = info:match("<[^>]*CurrentTransportState[^>]*>([^<]+)<") or ""
    st.playing = (st.state == "PLAYING")

    local pos = upnp_control(ip, port, "GetPositionInfo", "<InstanceID>0</InstanceID>")
    if pos then
        st.position = parse_time(pos:match("<[^>]*RelTime[^>]*>([^<]+)<"))
        st.duration = parse_time(pos:match("<[^>]*TrackDuration[^>]*>([^<]+)<"))

        local meta = pos:match("<[^>]*TrackMetaData[^>]*>([^<]*)</[^>]*TrackMetaData>")
        if meta and meta ~= "" then
            meta = xml_unescape(meta)
            st.title = meta:match("<dc:title>([^<]*)</dc:title>")
                or meta:match("<title>([^<]*)</title>") or ""
            st.artist = meta:match("<upnp:artist>([^<]*)</upnp:artist>")
                or meta:match("<artist>([^<]*)</artist>") or ""
            st.album = meta:match("<upnp:album>([^<]*)</upnp:album>")
                or meta:match("<album>([^<]*)</album>") or ""
            st.art = meta:match("<upnp:albumArtURI>([^<]*)</upnp:albumArtURI>") or ""
            if st.art ~= "" and not st.art:match("^https?://") then st.art = "" end
            st.streamurl = meta:match("<res[^>]*>([^<]*)</res>") or ""
            if st.streamurl == "" then
                st.streamurl = pos:match("<[^>]*TrackURI[^>]*>([^<]*)<") or ""
            end

            local cls = meta:match("<upnp:class>([^<]*)</upnp:class>") or ""
            if cls:match("musicTrack") then st.media = "歌曲"
            elseif cls:match("audioBroadcast") then st.media = "电台"
            elseif cls:match("audioItem") then st.media = "音频" end

            local mime = meta:match('protocolInfo="[^"]*:(audio/[^:;]+)')
                or meta:match("protocolInfo=[\"']audio/([^:;\"']+)")
            if mime then
                local m = mime:lower()
                if m:match("mpeg") then st.format = "MP3"
                elseif m:match("flac") then st.format = "FLAC"
                elseif m:match("mp4") or m:match("m4a") then st.format = "M4A/AAC"
                elseif m:match("wav") then st.format = "WAV"
                elseif m:match("ogg") then st.format = "OGG"
                elseif m:match("opus") then st.format = "OPUS"
                else st.format = mime end
            end
        end
    end

    local vol = upnp_control(ip, port, "GetVolume",
        "<InstanceID>0</InstanceID><Channel>Master</Channel>")
    if vol then
        st.volume = tonumber(vol:match("<[^>]*CurrentVolume[^>]*>([^<]+)<")) or 0
    end

    -- 输出声卡：和原插件页面一致，优先 gmediarender 的 -o/-d 参数，
    -- 没写参数时取 /proc/asound/cards 的第一张卡
    local pid = (sys.exec("pidof gmediarender 2>/dev/null") or ""):match("(%d+)")
    if pid then
        local cmdline = (fs.readfile("/proc/" .. pid .. "/cmdline") or ""):gsub("%z", " ")
        local out_arg = cmdline:match("%-o%s+([%w:%,%-]+)")
            or cmdline:match("%-d%s+([%w:%,%-]+)")
        if out_arg and out_arg ~= "" then st.soundcard = out_arg end
    end
    if st.soundcard == "" then
        local cards = fs.readfile("/proc/asound/cards") or ""
        local card_num, card_name = cards:match("(%d+)%s+%[.-%]:.-%-%s+([^\n]+)")
        if card_num and card_name then
            st.soundcard = "hw:" .. card_num .. " (" .. trim(card_name) .. ")"
        end
    end

    return st
end

local function gmr_control(action, value)
    local ip, port = lan_ip(), tonumber(uci_get("gmediarender", "gmediarender", "port", "49152")) or 49152
    local instance = "<InstanceID>0</InstanceID>"
    local resp, code

    if action == "play" then
        resp, code = upnp_control(ip, port, "Play", instance .. "<Speed>1</Speed>")
    elseif action == "pause" then
        resp, code = upnp_control(ip, port, "Pause", instance)
    elseif action == "stop" then
        resp, code = upnp_control(ip, port, "Stop", instance)
    elseif action == "next" then
        resp, code = upnp_control(ip, port, "Next", instance)
    elseif action == "previous" then
        resp, code = upnp_control(ip, port, "Previous", instance)
    elseif action == "seek" then
        local sec = math.max(0, tonumber(value) or 0)
        local h = math.floor(sec / 3600)
        local m = math.floor((sec % 3600) / 60)
        local s = math.floor(sec % 60)
        local target = string.format("%02d:%02d:%02d", h, m, s)
        resp, code = upnp_control(ip, port, "Seek",
            instance .. "<Unit>REL_TIME</Unit><Target>" .. target .. "</Target>")
    elseif action == "volume" then
        local v = math.max(0, math.min(100, tonumber(value) or 0))
        resp, code = upnp_control(ip, port, "SetVolume",
            instance .. "<Channel>Master</Channel><DesiredVolume>"
            .. tostring(math.floor(v)) .. "</DesiredVolume>")
    else
        return false, "不支持的 DLNA 操作: " .. tostring(action)
    end

    if not resp then return false, "GMediaRender 无响应" end
    -- 老版 nowplaying.htm 的 action_control 只判断 success=(res~=nil)，
    -- 不解析 SOAP 里的 500/701。很多 DLNA 渲染器在“手机端没有队列”时
    -- 会对 Next/Previous 返回 701，这里保持老行为：只要收到响应就算已发送，
    -- 避免切歌按钮每次点击都弹错误。
    if action == "next" or action == "previous" then
        return true
    end
    if code and code >= 200 and code < 300 then return true end

    local labels = {
        next = "下一曲", previous = "上一曲", seek = "跳转",
        volume = "音量", play = "播放", pause = "暂停", stop = "停止",
    }
    local label = labels[action] or action
    local errcode = resp:match("<errorCode>(%d+)</errorCode>")
    if errcode == "701" then
        return false, "当前 DLNA 推送端不支持" .. label .. "（播放队列在手机端）"
    end
    if code == 500 or code == 501 then
        return false, "当前 DLNA 推送端不支持" .. label
    end
    return false, "GMediaRender 返回 " .. tostring(code or "未知状态")
end

-- 保留原插件的“播放时自动下载”：以前由 LuCI 的 nowplaying 轮询触发，
-- 现在由音乐中心的状态轮询触发；只有打开音乐中心页面时才会执行，
-- 和旧行为一致（旧页面关闭后同样不会继续下载）。
local function trigger_download(url, title, artist)
    url = tostring(url or ""):gsub("&amp;", "&")
    if not url:match("^https?://") then return false, "无效链接" end

    local tool
    if sys.call("which wget >/dev/null 2>&1") == 0 then tool = "wget"
    elseif sys.call("which uclient-fetch >/dev/null 2>&1") == 0 then tool = "uclient-fetch" end
    if not tool then return false, "无下载工具" end

    local dir = uci_get("gmediarender", "gmediarender", "download_dir", "")
    if dir == "" then return false, "下载路径未配置" end
    if not dir:match("^/mnt") then return false, "下载目录必须在 /mnt 下" end
    if not fs.access(dir) then return false, "下载目录不存在" end

    local function sanitize(s)
        s = tostring(s or ""):gsub("[\\/:*?\"<>|]", "_")
        return trim(s)
    end

    local safe_title = sanitize(title)
    local safe_artist = sanitize(artist)
    if safe_title == "暂无播放" or safe_title == "空闲" then safe_title = "" end
    if safe_artist == "-" or safe_artist == "未知艺术家" then safe_artist = "" end

    local filename
    if safe_title ~= "" and safe_artist ~= "" then
        filename = safe_title .. "-" .. safe_artist
    elseif safe_title ~= "" then
        filename = safe_title
    else
        filename = url:match("([^/]+)$") or "download_song"
    end

    local ext = url:gsub("%?.*$", ""):match("%.([%a%d]+)$")
    if not ext or #ext > 4 then ext = "mp3" end
    if not filename:match("%.%w+$") then filename = filename .. "." .. ext end

    local filepath = dir .. "/" .. filename
    local logfile = "/tmp/gmediarender_dl.log"
    local lf = io.open(logfile, "w")
    if lf then
        lf:write("开始下载...\n")
        lf:close()
    end
    local cmd = string.format(
        "( env LANG=C.UTF-8 LC_ALL=C.UTF-8 %s -O %s %s >> %s 2>&1 & )",
        tool, shell_quote(filepath), shell_quote(url), shell_quote(logfile))
    sys.call(cmd)
    return true, filename
end

local function maybe_auto_download(st)
    if not st.playing then return false end
    if not st.streamurl or not st.streamurl:match("^https?://") then return false end
    if tostring(uci_get("gmediarender", "gmediarender", "auto_download", "0")) ~= "1" then
        return false
    end

    local last = ""
    if fs.access(GMR_LAST_DL) then last = trim(fs.readfile(GMR_LAST_DL) or "") end
    if last == st.streamurl then return false end

    local f = io.open(GMR_LAST_DL, "w")
    if f then f:write(st.streamurl); f:close() end

    local ok, file = trigger_download(st.streamurl, st.title, st.artist)
    return ok, file
end

-------------------------------------------------------------------------------
-- AirPlay / shairport-sync
-------------------------------------------------------------------------------

local function shairport_status()
    local st = {
        installed = installed("/usr/bin/shairport-sync", "/etc/config/shairport-sync"),
        enabled = plugin_enabled("shairport-sync", "shairport-sync"),
        running = process_running("shairport-sync"),
        playing = false,
        title = "", artist = "", album = "", lyric = "",
        volume = 0, client = "", client_ip = "",
        broadcast = uci_get("shairport-sync", "shairport-sync", "name", "AirPlay 2"),
        port = tonumber(uci_get("shairport-sync", "shairport-sync", "port", "5050")) or 5050,
        soundcard = "",
        cover = "", cover_ts = 0,
    }

    if fs.access("/tmp/shairport-now.json") then
        local raw = fs.readfile("/tmp/shairport-now.json") or "{}"
        local ok, d = pcall(jsonc.parse, raw)
        if ok and type(d) == "table" then
            st.title = tostring(d.title or "")
            st.artist = tostring(d.artist or "")
            st.album = tostring(d.album or "")
            st.lyric = tostring(d.lyric or "")
            st.volume = tonumber(d.volume) or 0
            st.client = tostring(d.snam or "")
            st.client_ip = tostring(d.clip or "")
            st.soundcard = tostring(d.soundcard or "")
            st.cover_ts = tonumber(d.cover_ts) or 0
            st.playing = (d.playing == true) and st.running
            if d.has_cover then
                st.cover = "/cgi-bin/luci/music/cover?service=shairport&t="
                    .. tostring(st.cover_ts)
            end
        end
    end
    if not st.running then st.playing = false end
    return st
end

-------------------------------------------------------------------------------
-- 聚合状态
-------------------------------------------------------------------------------

local function safe_call(fn, fallback, ...)
    local ok, res = pcall(fn, ...)
    if ok and type(res) == "table" then return res end
    local t = fallback or {}
    t.error = tostring(res)
    return t
end

local function pick_now(status)
    local order = {
        { "owntone", status.owntone },
        { "gmediarender", status.gmediarender },
        { "shairport", status.shairport },
    }

    for _, s in ipairs(order) do
        if s[2] and s[2].playing and s[2].title and s[2].title ~= "" then
            return { source = s[1], title = s[2].title, artist = s[2].artist or "" }
        end
    end
    for _, s in ipairs(order) do
        if s[2] and s[2].title and s[2].title ~= "" then
            return { source = s[1], title = s[2].title, artist = s[2].artist or "" }
        end
    end
    return { source = "none", title = "", artist = "" }
end

function action_status()
    if not guard(false) then return end

    http.header("Cache-Control", "no-store, max-age=0")
    http.prepare_content("application/json")

    local ip = lan_ip()
    local gmr_port = tonumber(uci_get("gmediarender", "gmediarender", "port", "49152")) or 49152

    local status = {
        ok = true,
        time = os.time(),
        hostname = sys.hostname() or "",
        physical = safe_call(resolve_soundcard, { available = false }),
        owntone = safe_call(owntone_status, { installed = false, running = false }),
        gmediarender = safe_call(gmr_status, { installed = false, running = false }, ip, gmr_port),
        shairport = safe_call(shairport_status, { installed = false, running = false }),
    }

    local auto_ok, auto_file = maybe_auto_download(status.gmediarender)
    status.gmediarender.auto_download_triggered = auto_ok
    status.gmediarender.auto_download_file = auto_file or ""
    status.now = pick_now(status)

    local running_n = 0
    local installed_n = 0
    for _, key in ipairs({ "owntone", "gmediarender", "shairport" }) do
        if status[key].running then running_n = running_n + 1 end
        if status[key].installed then installed_n = installed_n + 1 end
    end
    status.services = { total = 3, running = running_n, installed = installed_n }

    http.write(jsonc.stringify(status))
end

-------------------------------------------------------------------------------
-- 控制
-------------------------------------------------------------------------------

function action_control()
    if not require_post() then return end
    if not guard(true) then return end

    local service = http.formvalue("service") or ""
    local action = http.formvalue("action") or ""
    local value = http.formvalue("value")

    local ok, err
    if service == "owntone" then
        ok, err = owntone_control(action, value)
    elseif service == "gmediarender" then
        ok, err = gmr_control(action, value)
    else
        ok, err = false, "未知服务: " .. tostring(service)
    end
    respond(ok, err)
end

-- GMediaRender 当前音频源“下载到设备”（原 nowplaying.htm 的功能）
function action_download()
    if not require_post() then return end
    if not guard(true) then return end

    local url = http.formvalue("url") or ""
    local title = http.formvalue("title") or ""
    local artist = http.formvalue("artist") or ""

    http.prepare_content("application/json")
    if not url:match("^https?://") then
        http.write(jsonc.stringify({ ok = false, error = "无效链接" }))
        return
    end

    local ok, info = trigger_download(url, title, artist)
    if ok then
        http.write(jsonc.stringify({ ok = true, file = info }))
    else
        http.write(jsonc.stringify({ ok = false, error = info }))
    end
end

-- 下载日志（原 nowplaying.htm 的下载进度条使用）
function action_download_log()
    if not guard(false) then return end
    http.header("Cache-Control", "no-store, max-age=0")
    http.prepare_content("application/json")

    local data = ""
    if fs.access("/tmp/gmediarender_dl.log") then
        data = fs.readfile("/tmp/gmediarender_dl.log") or ""
        if #data > 6000 then data = data:sub(-6000) end
        data = data:gsub("\\(%d%d%d)", function(oct)
            return string.char(tonumber(oct, 8))
        end)
    end
    http.write(jsonc.stringify({ ok = true, log = data }))
end

function action_volume()
    if not require_post() then return end
    if not guard(true) then return end

    local target = http.formvalue("target") or "physical"
    local action = http.formvalue("action") or "set"
    local value = tonumber(http.formvalue("value")) or 0

    local ok, err
    if target == "physical" then
        ok, err = set_physical_volume(action, value)
    elseif target == "owntone" then
        if action == "mute" or action == "unmute" then
            ok, err = owntone_mute(action)
        else
            ok, err = owntone_set_volume(value)
        end
    elseif target == "gmediarender" then
        ok, err = gmr_control("volume", value)
    else
        ok, err = false, "未知音量目标: " .. tostring(target)
    end
    respond(ok, err)
end

-------------------------------------------------------------------------------
-- 服务启停
-------------------------------------------------------------------------------

local SERVICE_INIT = {
    owntone = "owntone",
    gmediarender = "gmediarender",
    shairport = "shairport-sync",
}

local SERVICE_UCI = {
    owntone = { "owntone", "owntone" },
    gmediarender = { "gmediarender", "gmediarender" },
    shairport = { "shairport-sync", "shairport-sync" },
}

local SERVICE_ACTION = {
    start = true, stop = true, restart = true, enable = true, disable = true,
}

local function service_action(name, action)
    local init_name = SERVICE_INIT[name]
    if not init_name then return false, "未知服务: " .. tostring(name) end
    if not SERVICE_ACTION[action] then return false, "未知操作: " .. tostring(action) end

    local init = "/etc/init.d/" .. init_name
    if not fs.access(init) then return false, "未安装服务: " .. init_name end

    if action == "enable" or action == "disable" then
        local cfg = SERVICE_UCI[name]
        if cfg then
            set_plugin_enabled(cfg[1], cfg[2], action == "enable" and "1" or "0")
        end
    end

    -- 放到后台，避免 restart 把 HTTP 请求卡住十几秒
    sys.call(init .. " " .. action .. " >/dev/null 2>&1 &")
    return true
end

function action_service()
    if not require_post() then return end
    if not guard(true) then return end

    local name = http.formvalue("name") or ""
    local action = http.formvalue("action") or ""

    if name == "all" then
        if action ~= "start" and action ~= "stop" and action ~= "restart" then
            respond(false, "全部操作只支持 start/stop/restart")
            return
        end
        for key in pairs(SERVICE_INIT) do
            service_action(key, action)
        end
        respond(true)
        return
    end

    local ok, err = service_action(name, action)
    respond(ok, err)
end

-------------------------------------------------------------------------------
-- 封面（AirPlay）
-------------------------------------------------------------------------------

function action_cover()
    if not guard(false) then return end

    local service = http.formvalue("service") or ""
    if service ~= "shairport" then
        http.status(404)
        return
    end

    local path = "/tmp/shairport-cover.jpg"
    if not fs.access(path) then
        http.status(404)
        return
    end

    local data = fs.readfile(path) or ""
    local ctype = "image/jpeg"
    -- AirPlay 的 PICT 可能是 JPEG 也可能是 PNG，按文件头给正确的类型
    if data:sub(1, 8) == "\137PNG\r\n\26\n" then ctype = "image/png" end
    http.header("Cache-Control", "no-store, max-age=0")
    http.prepare_content(ctype)
    http.write(data)
end
