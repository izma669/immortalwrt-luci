#!/usr/bin/lua

local PIPE  = "/tmp/shairport-sync-metadata"
local OUT   = "/tmp/shairport-now.json"
local COVER = "/tmp/shairport-cover.jpg"
local AIRPLAY_PORT = 5050

local state = {
    title = "", artist = "", album = "",
    lyric = "",
    volume = 0, playing = false,
    cover_ts = 0,
    snam = "", clip = "",
    soundcard = "",
    raw_minm = "", raw_asar = ""
}

local b64chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local b64dec = {}
for i = 1, 64 do b64dec[b64chars:sub(i,i)] = i - 1 end

local function b64decode(s)
    s = s:gsub("[^" .. b64chars:gsub("%+","%%+") .. "=]", "")
    local out = {}
    local i, n = 1, #s
    while i <= n do
        local c1 = s:sub(i,i); local c2 = s:sub(i+1,i+1)
        local c3 = s:sub(i+2,i+2); local c4 = s:sub(i+3,i+3)
        if c1 == "" or c1 == "=" then break end
        local b1 = b64dec[c1] or 0; local b2 = b64dec[c2] or 0
        local b3 = b64dec[c3] or 0; local b4 = b64dec[c4] or 0
        out[#out+1] = string.char(b1 * 4 + math.floor(b2 / 16))
        if c3 ~= "" and c3 ~= "=" then
            out[#out+1] = string.char((b2 % 16) * 16 + math.floor(b3 / 4))
        end
        if c4 ~= "" and c4 ~= "=" then
            out[#out+1] = string.char((b3 % 4) * 64 + b4)
        end
        i = i + 4
    end
    return table.concat(out)
end

local function hexdecode(s)
    s = s:gsub("%s", "")
    return (s:gsub("%x%x", function(h) return string.char(tonumber(h, 16)) end))
end

local function json_escape(s)
    s = s or ""
    return s:gsub("\\", "\\\\"):gsub('"', '\\"'):gsub("\n", "\\n"):gsub("\r", ""):gsub("\t", " ")
end

local function parse_title_artist()
    local minm = state.raw_minm or ""
    local asar = state.raw_asar or ""

    -- 1. QQ音乐/网易云："歌名 — 艺术家" 格式
    if asar ~= "" then
        local name, artist = asar:match("^(.-)%s+—%s+(.+)$")
        if not name then
            name, artist = asar:match("^(.-)%s+%-%s+(.+)$")
        end
        if name and artist and name ~= "" and artist ~= "" then
            state.title = name
            state.artist = artist
            state.lyric = minm
            return
        end
    end

    -- 2. 酷我："艺术家--歌名"
    local ar, al = asar:match("^(.-)[-][-](.+)$")
    if ar and ar ~= "" and al and al ~= "" then
        state.artist = ar
        state.title = al
        if minm:find(al, 1, true) then
            -- minm 里包含歌名 → minm 是歌名+杂项，不是歌词
            state.lyric = ""
        else
            -- minm 里不包含歌名 → minm 是歌词
            state.lyric = minm
        end
        return
    end

    -- 3. 兜底
    state.title = minm
    state.artist = asar
    state.lyric = ""
end

local function find_client_ip()
    local f = io.open("/proc/net/tcp", "r")
    if not f then return "" end
    local result = ""
    for line in f:lines() do
        local la, ra, st = line:match("^%s*%d+:%s+(%x+:%x+)%s+(%x+:%x+)%s+(%x+)")
        if st == "01" and la and ra then
            local lport = tonumber(la:match(":(%x+)$") or "0", 16)
            if lport == AIRPLAY_PORT then
                local rip_hex = ra:match("^(%x+):")
                if rip_hex and #rip_hex == 8 then
                    local d = tonumber(rip_hex:sub(1,2), 16)
                    local c = tonumber(rip_hex:sub(3,4), 16)
                    local b = tonumber(rip_hex:sub(5,6), 16)
                    local a = tonumber(rip_hex:sub(7,8), 16)
                    result = string.format("%d.%d.%d.%d", a, b, c, d)
                    break
                end
            end
        end
    end
    f:close()
    return result
end

local function find_hostname(ip)
    if not ip or ip == "" then return "" end
    local f = io.open("/tmp/dhcp.leases", "r")
    if not f then return "" end
    local name = ""
    for line in f:lines() do
        local lip, lname = line:match("^%S+%s+%S+%s+(%S+)%s+(%S+)")
        if lip == ip and lname and lname ~= "*" then name = lname; break end
    end
    f:close()
    return name
end

local function find_soundcard()
    local device = ""
    local f = io.open("/var/etc/shairport-sync-shairport_sync.conf", "r")
    if f then
        local content = f:read("*a")
        f:close()
        local alsa_block = content:match("alsa%s*=%s*{(.-)}")
        if alsa_block then
            device = alsa_block:match('output_device%s*=%s*"([^"]+)"') or ""
        end
    end
    if device == "" then device = "default" end

    local cards = {}
    local cf = io.open("/proc/asound/cards", "r")
    if cf then
        for line in cf:lines() do
            local idx, sname, drv, desc = line:match("^%s*(%d+)%s+%[([^%]]+)%]:%s+(%S+)%s+%-%s+(.+)$")
            if idx then
                cards[idx] = string.format("%s (%s)", desc:gsub("%s+$", ""), sname:gsub("%s+$", ""))
            end
        end
        cf:close()
    end

    if device == "default" then
        for idx, info in pairs(cards) do
            if info:match("[Uu][Ss][Bb]") then
                return "hw:" .. idx .. " - " .. info
            end
        end
        for idx = 0, 10 do
            if cards[tostring(idx)] then
                return "hw:" .. idx .. " - " .. cards[tostring(idx)]
            end
        end
        return "default (系统默认)"
    end

    local hwidx = device:match("hw:(%d+)")
    if hwidx and cards[hwidx] then
        return device .. " - " .. cards[hwidx]
    end
    return device
end

local function write_json()
    local has_cover = io.open(COVER, "r")
    local cover_flag = "false"
    if has_cover then has_cover:close(); cover_flag = "true" end

    local f = io.open(OUT, "w")
    if not f then return end
    f:write(string.format(
        '{"title":"%s","artist":"%s","album":"%s","lyric":"%s",' ..
        '"volume":%d,"playing":%s,"has_cover":%s,"cover_ts":%d,' ..
        '"snam":"%s","clip":"%s","soundcard":"%s"}',
        json_escape(state.title), json_escape(state.artist), json_escape(state.album),
        json_escape(state.lyric),
        state.volume, state.playing and "true" or "false", cover_flag, state.cover_ts,
        json_escape(state.snam), json_escape(state.clip),
        json_escape(state.soundcard)
    ))
    f:close()
end

local function handle_item(item)
    local clean = item:gsub("[\r\n]", "")
    local code_hex = clean:match("<code>([^<]*)</code>") or ""
    local data_b64 = clean:match('<data encoding="base64">([^<]*)</data>') or ""
    local code_str = hexdecode(code_hex)
    local raw = ""
    if data_b64 ~= "" then raw = b64decode(data_b64) end

    if code_str == "minm" then
        state.raw_minm = raw
        state.playing = true
        parse_title_artist()
    elseif code_str == "asar" then
        state.raw_asar = raw
        parse_title_artist()
    elseif code_str == "asal" then
        state.album = raw
    elseif code_str == "snam" then
        state.snam = raw
    elseif code_str == "clip" then
        state.clip = raw
    -- acre 字段是垃圾数据，忽略；AirPlay 格式固定，前端硬编码
    elseif code_str == "PICT" then
        if #raw > 500 then
            local tmpf = COVER .. ".tmp"
            local f = io.open(tmpf, "wb")
            if f then
                f:write(raw)
                f:close()
                os.rename(tmpf, COVER)
                state.cover_ts = os.time()
            end
        end
    elseif code_str == "pvol" then
        local first = raw:match("^([%-%d%.]+)")
        if first then
            local db = tonumber(first)
            if db then
                if db <= -144 or db <= -30 then state.volume = 0
                elseif db >= 0 then state.volume = 100
                else state.volume = math.floor(100 + db / 30 * 100 + 0.5) end
            end
        end
    elseif code_str == "pend" then
        state.playing = false
    end

    write_json()
end

os.remove(COVER)
os.remove(COVER .. ".tmp")
state.clip = find_client_ip()
state.snam = find_hostname(state.clip)
state.soundcard = find_soundcard()
write_json()

local buffer = ""
local counter = 0
while true do
    local pipe = io.open(PIPE, "r")
    if pipe then
        while true do
            local chunk = pipe:read(4096)
            if not chunk then break end
            buffer = buffer .. chunk
            while true do
                local s = buffer:find("<item>", 1, true)
                local e = buffer:find("</item>", 1, true)
                if not s or not e then break end
                handle_item(buffer:sub(s, e + 6))
                buffer = buffer:sub(e + 7)
            end
            if #buffer > 1048576 then buffer = buffer:sub(-65536) end
        end
        pipe:close()
    end

    counter = counter + 1
    if counter >= 5 then
        counter = 0
        local ip = find_client_ip()
        if ip ~= "" and ip ~= state.clip then
            state.clip = ip
            state.snam = find_hostname(ip)
            write_json()
        end
        local sc = find_soundcard()
        if sc ~= state.soundcard then
            state.soundcard = sc
            write_json()
        end
    end

    os.execute("sleep 1")
end
