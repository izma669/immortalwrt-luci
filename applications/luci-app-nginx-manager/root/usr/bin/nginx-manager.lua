#!/usr/bin/lua
-- DLNA 接收端发现守护进程
--
-- 作用：在本机 LAN 上通过 SSDP（M-SEARCH + NOTIFY）发现 MediaRenderer，
--       把控制 URL 写到 /tmp/dlna_devices.json，供 LuCI 的 /dlna/discover 使用。
-- 设计要点：
--   * 主动发送 M-SEARCH，而不是只被动等 NOTIFY（电视待机时不一定广播）；
--   * 固定走 LAN 接口的组播，避免从 WAN 口发出去；
--   * 解析设备 XML 时优先选 AVTransport 服务，而不是随便第一个 controlURL；
--   * 设备 15 分钟没再出现就过期，避免缓存里全是已经关掉的电视；
--   * 先写 .tmp 再 rename，避免 LuCI 读到半截 JSON。

local nixio = require "nixio"
local sys = require "luci.sys"
local jsonc = require "luci.jsonc"

local CACHE = "/tmp/dlna_devices.json"
local GROUP = "239.255.255.250"
local PORT = 1900
local EXPIRE = 900

local function shq(s)
    return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

-- 找 LAN 的 IPv4：优先 br-lan，其次第一个非 loopback 地址
local function lan_ip()
    local ok, ifs = pcall(nixio.getifaddrs)
    if ok and type(ifs) == "table" then
        local fallback
        for _, ifa in ipairs(ifs) do
            local name = ifa.name or ""
            local addr = ifa.addr or ""
            local fam = ifa.family or ""
            if fam == "inet" and name ~= "lo" and addr ~= "" and addr ~= "127.0.0.1" then
                if name == "br-lan" then return addr end
                if not fallback then fallback = addr end
            end
        end
        if fallback then return fallback end
    end

    -- nixio 接口枚举不可用时退回 UCI 的 LAN 地址
    local lan = sys.exec("uci get network.lan.ipaddr 2>/dev/null") or ""
    lan = lan:gsub("%s+$", "")
    if lan:match("^%d+%.%d+%.%d+%.%d+$") then return lan end
    return "0.0.0.0"
end

-- 从设备描述 XML 里取 friendlyName 和 AVTransport 的 controlURL
local function parse_device(xml, loc)
    if not xml or xml == "" then return nil end
    local name = xml:match("<[fF]riendlyName>(.-)</[fF]riendlyName>") or "未知设备"
    name = name:gsub("^%s+", ""):gsub("%s+$", "")

    local ctrl
    for svc in xml:gmatch("<service%s*>(.-)</service>") do
        local stype = svc:match("<serviceType>(.-)</serviceType>") or ""
        if stype:match("AVTransport") then
            ctrl = svc:match("<controlURL>(.-)</controlURL>")
            if ctrl then break end
        end
    end
    if not ctrl then
        ctrl = xml:match("<[cC]ontrolURL>(.-)</[cC]ontrolURL>")
    end
    if not ctrl then return nil end
    ctrl = ctrl:gsub("^%s+", ""):gsub("%s+$", "")

    local base = loc:match("^(https?://[^/]+)")
    if not base then return nil end
    if ctrl:match("^https?://") then return ctrl, name end
    if ctrl:sub(1, 1) ~= "/" then ctrl = "/" .. ctrl end
    return base .. ctrl, name
end

local devices = {}
local by_loc = {}

local function load_cache()
    local f = io.open(CACHE, "r")
    if not f then return end
    local content = f:read("*a") or ""
    f:close()
    local ok, arr = pcall(jsonc.parse, content)
    if not ok or type(arr) ~= "table" then return end
    local now = os.time()
    for _, d in ipairs(arr) do
        if type(d) == "table" and d.url and d.name then
            devices[d.url] = { name = d.name, loc = d.loc, seen = now }
            if d.loc then by_loc[d.loc] = d.url end
        end
    end
end

local function save_cache()
    local arr = {}
    for url, d in pairs(devices) do
        arr[#arr + 1] = { url = url, name = d.name, loc = d.loc, seen = d.seen }
    end
    local tmp = CACHE .. ".tmp"
    local f = io.open(tmp, "w")
    if not f then return end
    f:write(jsonc.stringify(arr))
    f:close()
    os.rename(tmp, CACHE)
end

local function handle_message(data)
    local loc = data:match("LOCATION:%s*([^\r\n]+)") or data:match("location:%s*([^\r\n]+)")
    if not loc then return end
    loc = loc:gsub("%s+$", "")
    if loc == "" then return end

    local now = os.time()
    local known = by_loc[loc]
    if known and devices[known] then
        devices[known].seen = now
        return
    end

    local xml = sys.exec("curl -s --connect-timeout 2 --max-time 4 " .. shq(loc))
    local ctrl, name = parse_device(xml, loc)
    if not ctrl then return end

    devices[ctrl] = { name = name, loc = loc, seen = now }
    by_loc[loc] = ctrl
    save_cache()
end

local function expire()
    local now = os.time()
    local changed = false
    for url, d in pairs(devices) do
        if now - (d.seen or 0) > EXPIRE then
            if d.loc then by_loc[d.loc] = nil end
            devices[url] = nil
            changed = true
        end
    end
    if changed then save_cache() end
end

local sock = nixio.socket("inet", "dgram")
if not sock then os.exit(1) end

pcall(function() sock:setopt("socket", "reuseaddr", 1) end)
pcall(function() sock:setopt("socket", "broadcast", 1) end)

local bind_ok, bind_rc = pcall(sock.bind, sock, "0.0.0.0", PORT)
local bound = bind_ok and (bind_rc == 0 or bind_rc == true)

local ip = lan_ip()
if bound then
    pcall(function() sock:setopt("ip", "add_membership", GROUP, ip) end)
else
    -- 1900 被 miniDLNA 等占用时，仍然可以用 M-SEARCH 的“临时端口 + 单播响应”发现设备
    io.stderr:write("dlna discover: port 1900 busy, fallback to M-SEARCH only\n")
end
pcall(function() sock:setopt("ip", "multicast_if", ip) end)
pcall(function() sock:setopt("socket", "rcvtimeo", 1) end)

load_cache()

local function send_search(st)
    local msg = "M-SEARCH * HTTP/1.1\r\n"
        .. "HOST: " .. GROUP .. ":" .. PORT .. "\r\n"
        .. 'MAN: "ssdp:discover"' .. "\r\n"
        .. "MX: 2\r\n"
        .. "ST: " .. st .. "\r\n"
        .. "\r\n"
    pcall(sock.sendto, sock, msg, GROUP, PORT)
end

local last_search = 0
local last_expire = 0

-- 先发一轮，既保证未绑定 1900 时 socket 也拿到临时端口，也加快开机发现
send_search("urn:schemas-upnp-org:device:MediaRenderer:1")
send_search("ssdp:all")
last_search = os.time()

while true do
    local now = os.time()
    if now - last_search >= 60 then
        -- MediaRenderer 和 ssdp:all 各发一次，兼容只响应其中一种的电视
        send_search("urn:schemas-upnp-org:device:MediaRenderer:1")
        send_search("ssdp:all")
        last_search = now
    end

    local data = sock:recvfrom(4096)
    if data then
        local ok, err = pcall(handle_message, data)
        if not ok then
            -- 单个坏包不能把守护进程带崩
            io.stderr:write("dlna discover: " .. tostring(err) .. "\n")
        end
    end

    if now - last_expire >= 30 then
        expire()
        last_expire = now
    end
end
