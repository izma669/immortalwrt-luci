#!/usr/bin/lua
local nixio = require "nixio"
local sys = require "luci.sys"

local sock = nixio.socket("inet", "dgram")
if not sock then os.exit(1) end
sock:setopt("socket", "reuseaddr", 1)
sock:setopt("socket", "broadcast", 1)

-- 绑定 1900 端口
sock:bind("0.0.0.0", 1900)

-- ★ 核心修复：显式加入多播组，去和 miniDLNA 抢数据
pcall(function() 
    sock:setopt("ip", "add_membership", "239.255.255.250", "0.0.0.0") 
end)

-- ★ 核心修复：设置 3 秒超时，防止死等卡死
sock:settimeout(3)

local devices = {}
local f = io.open("/tmp/dlna_devices.json", "r")
if f then
    local content = f:read("*a")
    f:close()
    for url, name in content:gmatch('"url":"(.-)","name":"(.-)"') do
        devices[url] = name
    end
end

local function save_cache()
    local file = io.open("/tmp/dlna_devices.json", "w")
    if not file then return end
    file:write("[")
    local first = true
    for url, name in pairs(devices) do
        if not first then file:write(",") end
        file:write('{"url":"' .. url .. '","name":"' .. name .. '"}')
        first = false
    end
    file:write("]")
    file:close()
end

while true do
    local data, addr = sock:recvfrom(4096)
    if data then
        local loc = data:match("LOCATION: (.-)\r\n") or data:match("location: (.-)\r\n")
        if loc then
            local exists = false
            for url, _ in pairs(devices) do
                if url:find(loc, 1, true) then exists = true break end
            end
            if not exists then
                -- 给 curl 加超时，防止解析 xml 时卡死
                local xml = sys.exec("curl -s --connect-timeout 2 --max-time 3 '" .. loc .. "'")
                local name = xml:match("<[fF]riendlyName>(.-)</[fF]riendlyName>") or "未知设备"
                local ctrl = xml:match("<[cC]ontrolURL>(.-)</[cC]ontrolURL>")
                if ctrl then
                    local base = loc:match("(http://[^/]+)")
                    if ctrl:sub(1,1) ~= "/" then ctrl = "/" .. ctrl end
                    devices[base .. ctrl] = name
                    save_cache()
                end
            end
        end
    end
end
