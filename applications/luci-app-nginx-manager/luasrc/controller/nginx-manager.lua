module("luci.controller.nginx-manager", package.seeall)

function index()
    if not nixio.fs.access("/etc/config/nginx") then
        return
    end

    -- 页面路由
    entry({"admin", "services", "nginx-manager"}, template("nginx-manager/overview"), _("Nginx 管理器"), 30).leaf = true
    entry({"admin", "services", "nginx-manager", "browse"}, call("browse_dir")).leaf = true
    entry({"admin", "services", "nginx-manager", "save"}, post("do_save")).leaf = true
    entry({"admin", "services", "nginx-manager", "toggle_server"}, post("do_toggle_server")).leaf = true
    entry({"admin", "services", "nginx-manager", "get_logs"}, call("get_logs")).leaf = true
    entry({"admin", "services", "nginx-manager", "clear_logs"}, post("clear_logs")).leaf = true

    -- ★ DLNA 接口路由（供 880 播放器调用）
    entry({"dlna", "discover"}, call("dlna_discover")).leaf = true
    entry({"dlna", "cast"}, post("dlna_cast")).leaf = true
    entry({"dlna", "probe"}, post("dlna_probe")).leaf = true
    entry({"dlna", "cover"}, call("dlna_cover")).leaf = true
    entry({"dlna", "control"}, post("dlna_control")).leaf = true
    entry({"dlna", "get_position"}, call("dlna_get_position")).leaf = true  -- ★ 新增路由
end

function dlna_discover()
    local http = require "luci.http"
    local devices = {}
    local f = io.open("/tmp/dlna_devices.json", "r")
    if f then
        local content = f:read("*a")
        f:close()
        for url, name in content:gmatch('"url":"(.-)","name":"(.-)"') do
            table.insert(devices, {name = name, control_url = url})
        end
    end
    http.prepare_content("application/json")
    http.write_json(devices)
end

function dlna_cast()
    local http = require "luci.http"
    local sys = require "luci.sys"
    local control_url = http.formvalue("control_url") or ""
    local video_url = http.formvalue("video_url") or ""
    if control_url == "" or video_url == "" then
        http.write_json({status = "error", message = "参数缺失"})
        return
    end
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
    if out1 ~= "000" and out2 ~= "000" then
        http.write_json({status = "success"})
    else
        http.write_json({status = "error", message = "无法连接设备，状态码: " .. out1 .. " / " .. out2})
    end
end

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
        http.write_json({status = "error", message = "未找到封面"})
    end
end

function dlna_control()
    local http = require "luci.http"
    local sys = require "luci.sys"
    local action = http.formvalue("action") or ""
    local ctrl_url = http.formvalue("control_url") or ""
    local value = http.formvalue("value") or ""

    if action == "" or ctrl_url == "" then
        http.write_json({status = "error", message = "参数缺失"})
        return
    end

    local target_url = ctrl_url
    local soap = ""

    if action == "pause" then
        soap = string.format([[<?xml version="1.0"?>
<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
<s:Body><u:Pause xmlns:u="urn:schemas-upnp-org:service:AVTransport:1"><InstanceID>0</InstanceID></u:Pause></s:Body></s:Envelope>]])
    elseif action == "play" then
        soap = string.format([[<?xml version="1.0"?>
<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
<s:Body><u:Play xmlns:u="urn:schemas-upnp-org:service:AVTransport:1"><InstanceID>0</InstanceID><Speed>1</Speed></u:Play></s:Body></s:Envelope>]])
    elseif action == "stop" then
        soap = string.format([[<?xml version="1.0"?>
<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
<s:Body><u:Stop xmlns:u="urn:schemas-upnp-org:service:AVTransport:1"><InstanceID>0</InstanceID></u:Stop></s:Body></s:Envelope>]])
    elseif action == "seek" then
        soap = string.format([[<?xml version="1.0"?>
<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
<s:Body><u:Seek xmlns:u="urn:schemas-upnp-org:service:AVTransport:1"><InstanceID>0</InstanceID><Unit>REL_TIME</Unit><Target>%s</Target></u:Seek></s:Body></s:Envelope>]], value)
    elseif action == "volume" then
        target_url = ctrl_url:gsub("AVTransport", "RenderingControl"):gsub("rendertransport", "rendercontrol")
        soap = string.format([[<?xml version="1.0"?>
<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
<s:Body><u:SetVolume xmlns:u="urn:schemas-upnp-org:service:RenderingControl:1"><InstanceID>0</InstanceID><Channel>Master</Channel><DesiredVolume>%s</DesiredVolume></u:SetVolume></s:Body></s:Envelope>]], value)
    end

    if soap == "" then
        http.write_json({status = "error", message = "不支持的指令"})
        return
    end

    local soap_action = "urn:schemas-upnp-org:service:AVTransport:1#" .. action:gsub("^%l", string.upper)
    if action == "volume" then
        soap_action = "urn:schemas-upnp-org:service:RenderingControl:1#SetVolume"
    end

    local cmd = string.format("curl -s -w '%%{http_code}' --connect-timeout 3 -X POST '%s' -H 'Content-Type: text/xml; charset=\"utf-8\"' -H 'SOAPAction: \"%s\"' -d '%s'", target_url, soap_action, soap:gsub("'", "'\\''"))
    local out = sys.exec(cmd)

    if out ~= "000" then
        http.write_json({status = "success", message = "指令已发送"})
    else
        http.write_json({status = "error", message = "连接失败: " .. out})
    end
end

-- ★ 获取远端 DLNA 播放进度（AirPin 完美支持版）
function dlna_get_position()
    local http = require "luci.http"
    local sys = require "luci.sys"
    local ctrl_url = http.formvalue("control_url") or ""

    if ctrl_url == "" then
        http.write_json({status = "error", message = "缺少 control_url"})
        return
    end

    -- ★ 关键：直接使用前端传来的原路径，不要再做任何字符串拼接或替换！
    -- AirPin 的路径：http://192.168.0.142:49153/upnp/control/rendertransport1

    local soap = string.format([[<?xml version="1.0"?>
<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
<s:Body><u:GetPositionInfo xmlns:u="urn:schemas-upnp-org:service:AVTransport:1">
<InstanceID>0</InstanceID></u:GetPositionInfo></s:Body></s:Envelope>]])

    local cmd = string.format("curl -s -w '%%{http_code}' --connect-timeout 1 --max-time 2 -X POST '%s' -H 'Content-Type: text/xml; charset=\"utf-8\"' -H 'SOAPAction: \"urn:schemas-upnp-org:service:AVTransport:1#GetPositionInfo\"' -d '%s'", ctrl_url, soap:gsub("'", "'\\''"))

    local out = sys.exec(cmd)
    local rel_time = out:match("<[rR]elTime>(.-)</[rR]elTime>")
    local track_duration = out:match("<[tT]rackDuration>(.-)</[tT]trackDuration>")
    local transport_state = out:match("<[tT]ransportState>(.-)</[tT]transportState>") -- 如果以后抓到了状态，也能用

    if rel_time then
        http.prepare_content("application/json")
        http.write_json({status = "success", rel_time = rel_time, duration = track_duration, state = transport_state})
    else
        http.prepare_content("application/json")
        http.write_json({status = "error", message = "设备未返回时间"})
    end
end
