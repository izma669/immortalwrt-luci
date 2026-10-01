module("luci.controller.gmediarender", package.seeall)

function index()
    if not nixio.fs.access("/etc/config/gmediarender") then return end
    entry({"admin", "services", "gmediarender"}, cbi("gmediarender"), _("GMediaRender"), 60).dependent = true
    entry({"admin", "services", "gmediarender", "status"}, call("action_status")).leaf = true
    entry({"admin", "services", "gmediarender", "nowplaying"}, call("action_nowplaying")).leaf = true
    entry({"admin", "services", "gmediarender", "download"}, call("action_download")).leaf = true
    entry({"admin", "services", "gmediarender", "download_log"}, call("action_download_log")).leaf = true
end

function action_status()
    local sys = require "luci.sys"
    local uci = require "luci.model.uci".cursor()
    local running = sys.call("pidof gmediarender >/dev/null") == 0
    local enabled = uci:get("gmediarender", "main", "enabled")
    luci.http.prepare_content("application/json")
    luci.http.write_json({ running = running, enabled = enabled == "1" })
end

function action_download_log()
    local fs = require "nixio.fs"
    local logfile = "/tmp/gmediarender_dl.log"
    local data = ""
    if fs.access(logfile) then
        data = fs.readfile(logfile) or ""
        if #data > 3000 then data = data:sub(-3000) end
    end
    luci.http.prepare_content("application/json")
    luci.http.write_json({ log = data })
end

function action_download()
    local http = require "luci.http"
    local uci = require "luci.model.uci".cursor()
    local sys = require "luci.sys"
    local fs = require "nixio.fs"
    
    local url = http.formvalue("url")
    local title = http.formvalue("title") or ""
    local artist = http.formvalue("artist") or ""
    
    if not url or url == "" then
        http.prepare_content("application/json")
        http.write_json({success = false, msg = "无效的链接"})
        return
    end
    
    if not url:match("^https?://") then
        http.prepare_content("application/json")
        http.write_json({success = false, msg = "链接必须以 http 或 https 开头"})
        return
    end
    
    -- 自动检测下载工具
    local tool = nil
    if sys.call("which wget >/dev/null 2>&1") == 0 then
        tool = "wget"
    elseif sys.call("which uclient-fetch >/dev/null 2>&1") == 0 then
        tool = "uclient-fetch"
    end
    
    if not tool then
        http.prepare_content("application/json")
        http.write_json({success = false, msg = "系统未找到 wget 或 uclient-fetch 工具，请先安装下载工具。"})
        return
    end
    
    local dir = uci:get("gmediarender", "main", "download_dir") or "/mnt/sda1/media/music"
    
    if not fs.access(dir) then
        sys.call("mkdir -p " .. string.format("%q", dir))
    end
    
    if not fs.access(dir) then
        http.prepare_content("application/json")
        http.write_json({success = false, msg = "无法创建或访问下载目录：" .. dir})
        return
    end
    
    -- 清理和拼接文件名的逻辑
    local function sanitize_filename(s)
        if not s then return "" end
        -- 替换非法字符为下划线，并去除首尾空格
        s = s:gsub("[\\/:*?\"<>|]", "_")
        s = s:gsub("^%s+", ""):gsub("%s+$", "")
        return s
    end
    
    local safe_title = sanitize_filename(title)
    local safe_artist = sanitize_filename(artist)
    
    -- 过滤掉无意义的占位符
    if safe_title == "暂无播放" or safe_title == "空闲" then safe_title = "" end
    if safe_artist == "-" or safe_artist == "未知艺术家" then safe_artist = "" end
    
    local filename = ""
    -- 核心拼接逻辑：歌曲名-演唱者
    if safe_title ~= "" and safe_artist ~= "" then
        filename = safe_title .. "-" .. safe_artist
    elseif safe_title ~= "" then
        filename = safe_title
    else
        -- 如果没有歌曲信息，回退到从 URL 提取文件名
        filename = url:match("([^/]+)$") or "download_song"
        filename = filename:match("([^?]+)") or filename
    end
    
    -- 提取扩展名（优先从 URL 获取，否则默认 .mp3）
    local ext = url:match("%.([%a%d]+)(?:$|%?)")
    if not ext or #ext > 4 then ext = "mp3" end
    
    -- 如果拼接后的文件名没有扩展名，自动补全
    if not filename:match("%.%w+$") then
        filename = filename .. "." .. ext
    end
    
    local filepath = dir .. "/" .. filename
    local logfile = "/tmp/gmediarender_dl.log"
    
    sys.call("echo '开始下载...' > " .. logfile)
    
    local cmd = ""
    if tool == "wget" then
        cmd = string.format("wget -O %s %s >> %s 2>&1 &", 
            string.format("%q", filepath), string.format("%q", url), logfile)
    else
        cmd = string.format("uclient-fetch -O %s %s >> %s 2>&1 &", 
            string.format("%q", filepath), string.format("%q", url), logfile)
    end
    
    sys.call(cmd)
    
    http.prepare_content("application/json")
    http.write_json({success = true, msg = "已开始后台下载:\n" .. filename})
end

function action_nowplaying()
    -- 保持原有逻辑不变
    local fs  = require "nixio.fs"
    local uci = require "luci.model.uci".cursor()
    local logfile = uci:get("gmediarender", "main", "logfile")
    if not logfile or logfile == "" then logfile = "/var/log/gmediarender.log" end

    local info = {
        playing=false, position="", duration="",
        title="", artist="", album="", albumart="",
        streamurl="", format="", quality="",
        volume="", playmode="", songid="",
        mediatype="", bitrate="", filesize="", debug="",
        soundcard=""
    }

    if not fs.access(logfile) then
        info.debug = "无法访问: " .. logfile
        luci.http.prepare_content("application/json")
        luci.http.write_json(info)
        return
    end

    local data = fs.readfile(logfile) or ""
    if #data > 4194304 then data = data:sub(-4194304) end

    local function last_match(pat)
        local r = nil
        for m in data:gmatch(pat) do r = m end
        return r
    end
    local function unescape(s)
        if not s then return "" end
        s = s:gsub("&lt;","<"):gsub("&gt;",">"):gsub("&quot;",'"'):gsub("&apos;","'"):gsub("&amp;","&")
        return s
    end

    info.title    = unescape(last_match("<dc:title>([^<]+)</dc:title>"))
    info.artist   = unescape(last_match("<upnp:artist>([^<]+)</upnp:artist>"))
    info.album    = unescape(last_match("<upnp:album>([^<]+)</upnp:album>"))
    info.albumart = unescape(last_match("<upnp:albumArtURI>([^<]+)</upnp:albumArtURI>"))
    if info.albumart ~= "" and not info.albumart:match("^https?://") then info.albumart = "" end

    local cls = last_match("<upnp:class>([^<]+)</upnp:class>")
    if cls then
        if cls:match("musicTrack") then info.mediatype = "歌曲"
        elseif cls:match("audioBroadcast") then info.mediatype = "电台"
        elseif cls:match("audioItem") then info.mediatype = "音频"
        elseif cls:match("videoItem") then info.mediatype = "视频"
        else info.mediatype = cls end
    end

    local mime = last_match("protocolInfo=\"[^\"]*:(audio/[^:;]+)")
    if mime then
        if mime:match("mpeg") then info.format = "MP3"
        elseif mime:match("flac") then info.format = "FLAC"
        elseif mime:match("mp4") or mime:match("m4a") then info.format = "M4A/AAC"
        elseif mime:match("wav") then info.format = "WAV"
        elseif mime:match("ogg") then info.format = "OGG"
        elseif mime:match("wma") then info.format = "WMA"
        elseif mime:match("opus") then info.format = "OPUS"
        else info.format = mime end
    end

    local itemid = last_match("<item id=\"([A-Z]+):")
    if itemid == "SQ" then info.quality = "无损"
    elseif itemid == "HQ" then info.quality = "高品质"
    elseif itemid == "LQ" then info.quality = "普通"
    elseif itemid == "PQ" then info.quality = "流畅"
    elseif itemid then info.quality = itemid end

    local res_attrs = last_match("<res[^>]*protocolInfo=[^>]*>")
    if res_attrs then
        local sz = res_attrs:match("size=\"(%d+)\"")
        if sz then info.filesize = sz end
        local br = res_attrs:match("bitrate=\"(%d+)\"")
        if br then info.bitrate = tostring(math.floor(tonumber(br) / 1000)) end
    end

    if info.bitrate == "" then
        local est = nil
        if info.quality == "无损" then est = 900
        elseif info.quality == "高品质" then est = 320
        elseif info.quality == "普通" then est = 128
        elseif info.quality == "流畅" then est = 64
        elseif info.format == "FLAC" or info.format == "WAV" then est = 900
        elseif info.format == "MP3" or info.format == "M4A/AAC" then est = 128
        elseif info.format == "OPUS" then est = 96 end
        if est then info.bitrate = "~" .. est end
    end

    if info.filesize ~= "" and info.duration ~= "" then
        local h, m, s = info.duration:match("(%d+):(%d+):(%d+)")
        if h then
            local total = tonumber(h)*3600 + tonumber(m)*60 + tonumber(s)
            if total > 0 then
                local kbps = math.floor(tonumber(info.filesize) * 8 / total / 1000)
                info.bitrate = tostring(kbps)
            end
        end
    end

    local uri = last_match("CurrentTrackURI:%s*(%S+)")
    if not uri or uri == "" then uri = last_match("AVTransportURI:%s*(%S+)") end
    if uri then info.streamurl = uri end

    local sid = last_match("<qq:songID>(%d+)</qq:songID>")
    if sid then info.songid = sid end

    info.position = last_match("RelativeTimePosition:%s*([%d:]+)") or ""
    info.duration = last_match("CurrentTrackDuration:%s*([%d:]+)") or ""

    local vol = last_match("Volume:%s*(%d+)")
    if vol then info.volume = vol end

    local pm = last_match("CurrentPlayMode val=\"(%u+)\"")
    if pm == "NORMAL" then info.playmode = "顺序播放"
    elseif pm == "SHUFFLE" then info.playmode = "随机播放"
    elseif pm == "REPEAT_ONE" then info.playmode = "单曲循环"
    elseif pm == "REPEAT_ALL" then info.playmode = "列表循环"
    elseif pm then info.playmode = pm end

    local state = last_match("TransportState:%s*(%u[%u_]+)") or "-"
    if state == "PLAYING" then info.playing = true end
    if state == "STOPPED" then info.position = "" end

    local sys = require "luci.sys"
    local soundcard = uci:get("gmediarender", "main", "soundcard") or uci:get("gmediarender", "main", "output") or uci:get("gmediarender", "main", "device")
    if not soundcard or soundcard == "" then
        local ps_out = sys.exec("ps w | grep gmediarender | grep -v grep")
        local out_arg = ps_out:match("%-o%s+([%w:%,%-]+)") or ps_out:match("%-d%s+([%w:%,%-]+)")
        if out_arg then
            soundcard = out_arg
        else
            local proc_cards = sys.exec("cat /proc/asound/cards 2>/dev/null")
            if proc_cards and proc_cards ~= "" then
                local card_num, card_name = proc_cards:match("(%d+) %[.-%]:.-%-%s+(.+)")
                if card_num and card_name then
                    soundcard = "hw:" .. card_num .. " - " .. card_name
                end
            end
        end
    end
    if not soundcard or soundcard == "" then soundcard = "-" end
    info.soundcard = soundcard

    info.debug = string.format("%s | state=%s | type=%s | fmt=%s | q=%s | br=%s | vol=%s | sc=%s",
        logfile, state,
        info.mediatype ~= "" and info.mediatype or "-",
        info.format ~= "" and info.format or "-",
        info.quality ~= "" and info.quality or "-",
        info.bitrate ~= "" and info.bitrate or "-",
        info.volume ~= "" and info.volume or "-",
        info.soundcard)

    luci.http.prepare_content("application/json")
    luci.http.write_json(info)
end
