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

    -- ★ 关键补漏：DLNA 接口路由（供 880 播放器调用）
    entry({"dlna", "discover"}, call("dlna_discover")).leaf = true
    entry({"dlna", "cast"}, post("dlna_cast")).leaf = true
    entry({"dlna", "probe"}, post("dlna_probe")).leaf = true
    entry({"dlna", "cover"}, call("dlna_cover")).leaf = true
end

-- ========== 以下函数可以直接沿用你路由器里现有的 ==========
-- 为了省事，我把最关键的 dlna_discover 和 dlna_cast 复制过来：
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

-- 其他的 do_save, get_logs 等函数你路由器里本来就有，不需要重复写，LuCI 会自动合并
