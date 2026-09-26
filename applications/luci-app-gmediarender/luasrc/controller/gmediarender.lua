module("luci.controller.gmediarender", package.seeall)

function index()
    if not nixio.fs.access("/etc/config/gmediarender") then return end

    entry({"admin", "services", "gmediarender"},
        cbi("gmediarender"),
        _("GMediaRender"), 60).dependent = true

    entry({"admin", "services", "gmediarender", "status"},
        call("action_status")).leaf = true

    entry({"admin", "services", "gmediarender", "nowplaying"},
        call("action_nowplaying")).leaf = true
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
        playing = false, position = "", duration = "",
        title = "", artist = "", album = "", albumart = "",
        streamurl = "", debug = ""
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
        s = s:gsub("&lt;", "<")
        s = s:gsub("&gt;", ">")
        s = s:gsub("&quot;", '"')
        s = s:gsub("&apos;", "'")
        s = s:gsub("&amp;", "&")
        return s
    end

    info.title    = unescape(last_match("<dc:title>([^<]+)</dc:title>"))
    info.artist   = unescape(last_match("<upnp:artist>([^<]+)</upnp:artist>"))
    info.album    = unescape(last_match("<upnp:album>([^<]+)</upnp:album>"))
    info.albumart = unescape(last_match("<upnp:albumArtURI>([^<]+)</upnp:albumArtURI>"))

    if info.albumart ~= "" and not info.albumart:match("^https?://") then
        info.albumart = ""
    end

    -- 音频流真实地址：优先取 CurrentTrackURI，回退到 AVTransportURI
    local uri = last_match("CurrentTrackURI:%s*(%S+)")
    if not uri or uri == "" then
        uri = last_match("AVTransportURI:%s*(%S+)")
    end
    if uri then info.streamurl = uri end

    info.position = last_match("RelativeTimePosition:%s*([%d:]+)") or ""
    info.duration = last_match("CurrentTrackDuration:%s*([%d:]+)") or ""
    local state = last_match("TransportState:%s*(%u[%u_]+)") or "-"

    if state == "PLAYING" then info.playing = true end
    if state == "STOPPED" then info.position = "" end

    local dbg_pos = info.position; if dbg_pos == "" then dbg_pos = "-" end
    local dbg_dur = info.duration; if dbg_dur == "" then dbg_dur = "-" end
    info.debug = logfile .. " | pos=" .. dbg_pos .. " | dur=" .. dbg_dur .. " | state=" .. state

    luci.http.prepare_content("application/json")
    luci.http.write_json(info)
end
