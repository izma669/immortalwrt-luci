module("luci.controller.gmediarender", package.seeall)

function index()
    if not nixio.fs.access("/etc/config/gmediarender") then return end
    entry({"admin", "services", "gmediarender"}, cbi("gmediarender"), _("GMediaRender"), 60).dependent = true
    entry({"admin", "services", "gmediarender", "status"}, call("action_status")).leaf = true
    entry({"admin", "services", "gmediarender", "nowplaying"}, call("action_nowplaying")).leaf = true
end

function action_status()
    local sys = require "luci.sys"
    local uci = require "luci.model.uci".cursor()
    local running = sys.call("pidof gmediarender >/dev/null") == 0
    local enabled = uci:get("gmediarender", "main", "enabled")
    luci.http.prepare_content("application/json")
    luci.http.write_json({ running = running, enabled = enabled == "1" })
end

function action_nowplaying()
    local fs  = require "nixio.fs"
    local uci = require "luci.model.uci".cursor()
    local logfile = uci:get("gmediarender", "main", "logfile")
    if not logfile or logfile == "" then logfile = "/var/log/gmediarender.log" end

    local info = {
        playing=false, position="", duration="",
        title="", artist="", album="", albumart="",
        streamurl="", format="", quality="",
        volume="", playmode="", songid="",
        mediatype="", bitrate="", filesize="", debug=""
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

    -- ============ 媒体类型：歌曲 / 电台 ============
    local cls = last_match("<upnp:class>([^<]+)</upnp:class>")
    if cls then
        if cls:match("musicTrack") then info.mediatype = "歌曲"
        elseif cls:match("audioBroadcast") then info.mediatype = "电台"
        elseif cls:match("audioItem") then info.mediatype = "音频"
        elseif cls:match("videoItem") then info.mediatype = "视频"
        else info.mediatype = cls end
    end

    -- ============ 音频格式 ============
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

    -- ============ 音质等级 ============
    local itemid = last_match("<item id=\"([A-Z]+):")
    if itemid == "SQ" then info.quality = "无损"
    elseif itemid == "HQ" then info.quality = "高品质"
    elseif itemid == "LQ" then info.quality = "普通"
    elseif itemid == "PQ" then info.quality = "流畅"
    elseif itemid then info.quality = itemid end

    -- ============ 码率 / 文件大小 ============
    -- 优先从 res 标签的 size 和 bitrate 属性读取（推送端一般不提供）
    local res_attrs = last_match("<res[^>]*protocolInfo=[^>]*>")
    if res_attrs then
        local sz = res_attrs:match("size=\"(%d+)\"")
        if sz then info.filesize = sz end
        local br = res_attrs:match("bitrate=\"(%d+)\"")
        if br then info.bitrate = tostring(math.floor(tonumber(br) / 1000)) end
    end

    -- 若推送端未提供码率，则按音质等级估算（前面加 ~ 表示估值）
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

    -- 若能从 duration 和 filesize 反推码率，则用真实值覆盖估算
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

    -- ============ 音频流地址 ============
    local uri = last_match("CurrentTrackURI:%s*(%S+)")
    if not uri or uri == "" then uri = last_match("AVTransportURI:%s*(%S+)") end
    if uri then info.streamurl = uri end

    -- ============ 歌曲 ID ============
    local sid = last_match("<qq:songID>(%d+)</qq:songID>")
    if sid then info.songid = sid end

    -- ============ 进度与总时长 ============
    info.position = last_match("RelativeTimePosition:%s*([%d:]+)") or ""
    info.duration = last_match("CurrentTrackDuration:%s*([%d:]+)") or ""

    -- ============ 音量 ============
    local vol = last_match("Volume:%s*(%d+)")
    if vol then info.volume = vol end

    -- ============ 播放模式 ============
    local pm = last_match("CurrentPlayMode val=\"(%u+)\"")
    if pm == "NORMAL" then info.playmode = "顺序播放"
    elseif pm == "SHUFFLE" then info.playmode = "随机播放"
    elseif pm == "REPEAT_ONE" then info.playmode = "单曲循环"
    elseif pm == "REPEAT_ALL" then info.playmode = "列表循环"
    elseif pm then info.playmode = pm end

    -- ============ 播放状态 ============
    local state = last_match("TransportState:%s*(%u[%u_]+)") or "-"
    if state == "PLAYING" then info.playing = true end
    if state == "STOPPED" then info.position = "" end

    info.debug = string.format("%s | state=%s | type=%s | fmt=%s | q=%s | br=%s | vol=%s",
        logfile, state,
        info.mediatype ~= "" and info.mediatype or "-",
        info.format ~= "" and info.format or "-",
        info.quality ~= "" and info.quality or "-",
        info.bitrate ~= "" and info.bitrate or "-",
        info.volume ~= "" and info.volume or "-")

    luci.http.prepare_content("application/json")
    luci.http.write_json(info)
end
