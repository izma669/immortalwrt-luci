module("luci.controller.nginx-manager", package.seeall)

function index()
    if not nixio.fs.access("/etc/config/nginx") then
        return
    end

    entry({"admin", "services", "nginx-manager"},
          template("nginx-manager/overview"),
          _("Nginx 管理器"), 30).leaf = true

    entry({"admin", "services", "nginx-manager", "browse"},
          call("browse_dir")).leaf = true

    entry({"admin", "services", "nginx-manager", "save"},
          post("do_save")).leaf = true

    -- ★ DLNA 路由
    entry({"dlna", "discover"}, call("dlna_discover")).leaf = true
    entry({"dlna", "cast"}, post("dlna_cast")).leaf = true
    entry({"dlna", "probe"}, post("dlna_probe")).leaf = true
    entry({"dlna", "cover"}, call("dlna_cover")).leaf = true

    -- ★ 日志路由
    entry({"admin", "services", "nginx-manager", "get_logs"}, call("get_logs")).leaf = true
    entry({"admin", "services", "nginx-manager", "clear_logs"}, post("clear_logs")).leaf = true
end

-- AJAX 目录浏览
function browse_dir()
    local http = require "luci.http"
    local sys = require "luci.sys"
    local path = http.formvalue("path") or "/mnt"
    if not path:match("^/mnt") then path = "/mnt" end
    local safe = path:gsub("'", "'\\''")
    local out = sys.exec("ls -1p '" .. safe .. "' 2>/dev/null | grep '/$' | sed 's|/$||'")
    local dirs = {}
    for name in out:gmatch("[^\n]+") do table.insert(dirs, name) end
    http.prepare_content("application/json")
    http.write_json(dirs)
end

-- 读取当前 media.conf 中的端口和根目录
local function get_current_media_config()
    local conf_path = "/etc/nginx/conf.d/media.conf"
    local f = io.open(conf_path, "r")
    if not f then return "880", "/mnt" end
    local content = f:read("*a")
    f:close()
    local port = content:match("listen%s+(%d+)%s+default_server") or "880"
    local root_dir = content:match("location%s+/%s*{%s*root%s+([^;]+);") or "/mnt"
    return port, root_dir
end

-- 生成完整的 media.conf 配置
local function generate_media_conf(port, root_dir)
    local alias_dir = root_dir
    if not alias_dir:match("/$") then alias_dir = alias_dir .. "/" end
    alias_dir = alias_dir:gsub("%%", "%%%%")
    local safe_root = root_dir:gsub("%%", "%%%%")
    return string.format([[
server {
    listen %s default_server;
    listen [::]:%s default_server;
    server_name _lan;

    location = /player.html { root /www; }
    location = /mpegts.min.js { root /www; }

    location /cgi-bin/luci/ {
        proxy_pass http://127.0.0.1:80;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    }

    location /api/dir/ {
        alias %s;
        autoindex on;
        autoindex_format json;
        autoindex_exact_size on;
    }

    location ~* \.(mp4|webm|mkv|mov|avi|m4v|ogv|flv|3gp|ts|m2ts|wmv|mp3|m4a|flac|aac|ogg|wav)$ {
        root %s;
        add_header Accept-Ranges bytes;
        add_header Cache-Control "public, max-age=3600";
    }

    location / {
        root %s;
        try_files $uri /player.html;
    }
}
]], port, port, alias_dir, safe_root, safe_root)
end

-- 保存逻辑（仅修改 media.conf）
function do_save()
    local http = require "luci.http"
    local sys = require "luci.sys"
    local action = http.formvalue("action") or ""
    local port, root_dir = get_current_media_config()

    if action == "change_port" then
        local new_port = http.formvalue("new_port")
        if new_port and new_port:match("^%d+$") then port = new_port end
    elseif action == "change_root" then
        local new_root = http.formvalue("new_root")
        if new_root and new_root:match("^/") then root_dir = new_root end
    end

    local conf = generate_media_conf(port, root_dir)
    local f = io.open("/etc/nginx/conf.d/media.conf", "w")
    if f then f:write(conf); f:close() end

    -- 保存后直接重载 Nginx 生效，不涉及任何旧文件删除
    sys.exec("/etc/init.d/nginx reload")
    http.redirect(http.getenv("REQUEST_URI") or "/cgi-bin/luci/admin/services/nginx-manager")
end

-- ★ DLNA 发现设备
function dlna_discover()
    local http = require "luci.http"
    local sys = require "luci.sys"
    local ok, nixio = pcall(require, "nixio")
    local devices = {}
    if not ok or not nixio or not nixio.socket then
        http.write_json(devices)
        return
    end
    local sock = nixio.socket("inet", "dgram")
    if not sock then http.write_json(devices); return end
    sock:setopt("socket", "broadcast", 1)
    sock:setopt("socket", "rcvtimeo", 2)
    sock:bind("0.0.0.0", 0)
    local msg_all = 'M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\nMAN: "ssdp:discover"\r\nMX: 2\r\nST: ssdp:all\r\n\r\n'
    sock:sendto(msg_all, "239.255.255.250", 1900)
    local msg_mr = 'M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\nMAN: "ssdp:discover"\r\nMX: 2\r\nST: urn:schemas-upnp-org:device:MediaRenderer:1\r\n\r\n'
    sock:sendto(msg_mr, "239.255.255.250", 1900)
    for _ = 1, 2 do
        while true do
            local data, addr = sock:recvfrom(4096)
            if not data then break end
            local loc = data:match("LOCATION: (.-)\r\n") or data:match("location: (.-)\r\n")
            if loc then
                local xml = sys.exec("curl -s --connect-timeout 2 '" .. loc .. "'")
                local name = xml:match("<[fF]riendlyName>(.-)</[fF]riendlyName>") or "未知设备"
                local ctrl = xml:match("<[cC]ontrolURL>(.-)</[cC]ontrolURL>")
                if ctrl then
                    local base = loc:match("(http://[^/]+)")
                    if ctrl:sub(1,1) ~= "/" then ctrl = "/" .. ctrl end
                    local ctrl_url = base .. ctrl
                    local exists = false
                    for _, d in ipairs(devices) do
                        if d.control_url == ctrl_url then exists = true break end
                    end
                    if not exists then
                        table.insert(devices, {name = name, control_url = ctrl_url})
                    end
                end
            end
        end
    end
    sock:close()
    http.write_json(devices)
end

-- ★ 自动探测端口
function dlna_probe()
    local http = require "luci.http"
    local sys = require "luci.sys"
    local ip = http.formvalue("ip") or ""
    if not ip:match("^%d+%.%d+%.%d+%.%d+$") then http.write_json({status = "error", message = "IP格式错误"}); return end
    local ports = {49152, 9197, 8008, 8080, 1400, 49153, 9199, 80, 9000, 5000, 5001, 32469, 2869, 10243, 49154, 49155, 49156, 49157}
    for _, port in ipairs(ports) do
        local xml = sys.exec("curl -s --connect-timeout 1 --max-time 2 'http://" .. ip .. ":" .. port .. "/description.xml'")
        if xml and xml:match("<[cC]ontrolURL>") then
            local base = "http://" .. ip .. ":" .. port
            local ctrl = xml:match("<[cC]ontrolURL>(.-)</[cC]ontrolURL>")
            if ctrl then
                if ctrl:sub(1,1) ~= "/" then ctrl = "/" .. ctrl end
                http.write_json({status = "success", control_url = base .. ctrl})
                return
            end
        end
        local test_ctrl = sys.exec("curl -s --connect-timeout 1 --max-time 2 -o /dev/null -w '%{http_code}' 'http://" .. ip .. ":" .. port .. "/AVTransport/control'")
        if test_ctrl == "200" or test_ctrl == "405" or test_ctrl == "500" then
            http.write_json({status = "success", control_url = "http://" .. ip .. ":" .. port .. "/AVTransport/control"})
            return
        end
    end
    http.write_json({status = "error", message = "未找到可用的 DLNA 控制端口"})
end

-- ★ 发送投屏指令
function dlna_cast()
    local http = require "luci.http"
    local sys = require "luci.sys"
    local control_url = http.formvalue("control_url") or ""
    local video_url = http.formvalue("video_url") or ""
    if control_url == "" or video_url == "" then http.write_json({status = "error", message = "参数缺失"}); return end
    local soap1 = string.format([[<?xml version="1.0"?>
<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
<s:Body><u:SetAVTransportURI xmlns:u="urn:schemas-upnp-org:service:AVTransport:1">
<InstanceID>0</InstanceID><CurrentURI>%s</CurrentURI><CurrentURIMetaData></CurrentURIMetaData>
</u:SetAVTransportURI></s:Body></s:Envelope>]], video_url)
    local soap2 = [[<?xml version="1.0"?>
<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
<s:Body><u:Play xmlns:u="urn:schemas-upnp-org:service:AVTransport:1">
<InstanceID>0</InstanceID><Speed>1</Speed>
</u:Play></s:Body></s:Envelope>]]
    local cmd = string.format("curl -s -w '%%{http_code}' --connect-timeout 3 -X POST '%s' -H 'Content-Type: text/xml; charset=\"utf-8\"' -H 'SOAPAction: \"urn:schemas-upnp-org:service:AVTransport:1#SetAVTransportURI\"' -d '%s'", control_url, soap1:gsub("'", "'\\''"))
    local out1 = sys.exec(cmd)
    cmd = string.format("curl -s -w '%%{http_code}' --connect-timeout 3 -X POST '%s' -H 'Content-Type: text/xml; charset=\"utf-8\"' -H 'SOAPAction: \"urn:schemas-upnp-org:service:AVTransport:1#Play\"' -d '%s'", control_url, soap2:gsub("'", "'\\''"))
    local out2 = sys.exec(cmd)
    if out1:match("200") and out2:match("200") then
        http.write_json({status = "success"})
    else
        http.write_json({status = "error", message = "HTTP Status: " .. out1 .. " / " .. out2})
    end
end

-- ★ 获取日志
function get_logs()
    local http = require "luci.http"
    local sys = require "luci.sys"
    local log_type = http.formvalue("type") or "error"
    if log_type ~= "error" and log_type ~= "access" then log_type = "error" end
    local log_path = "/var/log/nginx/" .. log_type .. ".log"
    if not nixio.fs.access(log_path) then log_path = "/tmp/log/nginx/" .. log_type .. ".log" end
    if not nixio.fs.access(log_path) then log_path = "/tmp/nginx-" .. log_type .. ".log" end
    local out = sys.exec("tail -n 200 '" .. log_path .. "' 2>/dev/null")
    if not out or out == "" then out = "日志文件不存在或为空。\n尝试查看的路径: " .. log_path end
    http.prepare_content("text/plain; charset=utf-8")
    http.write(out)
end

-- ★ 清空日志
function clear_logs()
    local http = require "luci.http"
    local sys = require "luci.sys"
    local log_type = http.formvalue("type") or "error"
    if log_type ~= "error" and log_type ~= "access" then log_type = "error" end
    local log_path = "/var/log/nginx/" .. log_type .. ".log"
    if not nixio.fs.access(log_path) then log_path = "/tmp/log/nginx/" .. log_type .. ".log" end
    if not nixio.fs.access(log_path) then log_path = "/tmp/nginx-" .. log_type .. ".log" end
    sys.exec("echo -n > '" .. log_path .. "' 2>/dev/null")
    http.prepare_content("application/json")
    http.write_json({status = "success"})
end

-- ★ 自动联网获取歌曲封面
function dlna_cover()
    local http = require "luci.http"
    local sys = require "luci.sys"
    local title = http.formvalue("title") or ""
    local query = title:gsub("%[.-%]", ""):gsub("%(.-%)", ""):gsub("《.-》", "")
    query = query:gsub("^%d+%s*", ""):gsub("^%s+", ""):gsub("%s+$", "")
    if query == "" then query = title end
    local cmd = string.format([[curl -s -G -k --connect-timeout 5 --max-time 10 'https://itunes.apple.com/search' --data-urlencode 'term=%s' --data-urlencode 'entity=song' --data-urlencode 'limit=1']], query:gsub("'", "'\\''"))
    local json_str = sys.exec(cmd)
    local artwork = json_str:match('"artworkUrl100":"([^"]+)"')
    if artwork then
        artwork = artwork:gsub("100x100", "600x600")
        http.prepare_content("application/json")
        http.write_json({status = "success", url = artwork})
    else
        http.prepare_content("application/json")
        http.write_json({status = "error", message = "iTunes 未找到匹配封面，原始搜索词: " .. query})
    end
end
