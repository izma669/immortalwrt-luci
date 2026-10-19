module("luci.controller.nginx-manager", package.seeall)

function index()
    entry({"admin", "services", "nginx-manager"}, template("nginx-manager/overview"), _("Nginx 管理器"), 30).leaf = true
    entry({"dlna", "discover"}, call("dlna_discover")).leaf = true
    entry({"dlna", "cast"}, post("dlna_cast")).leaf = true
    entry({"dlna", "probe"}, post("dlna_probe")).leaf = true
    entry({"dlna", "cover"}, call("dlna_cover")).leaf = true
    entry({"dlna", "control"}, post("dlna_control")).leaf = true
    entry({"dlna", "get_position"}, call("dlna_get_position")).leaf = true
    entry({"dlna", "ffprobe"}, post("dlna_ffprobe")).leaf = true 
end

function dlna_ffprobe()
    local http = require "luci.http"
    http.prepare_content("application/json")
    
    local file = http.formvalue("file") or ""
    if file == "" then
        http.write('{"error":"缺少 file 参数"}')
        return 
    end
    
    -- ★ 核心修复 1：双重 URL 解码，暴力解析出中文和特殊字符
    local function unescape(s)
        return (s:gsub('%%(%x%x)', function(x) return string.char(tonumber(x, 16)) end))
    end
    file = unescape(file)
    if file:match("%%") then 
        file = unescape(file) 
    end
    
    local path = "/mnt" .. file
    local f_test = io.open(path, "rb")
    if not f_test then
        local alt_path = "/mnt/mmcblk0p1" .. file
        local f_alt = io.open(alt_path, "rb")
        if f_alt then
            f_alt:close()
            path = alt_path
        else
            http.write('{"error":"文件不存在或无法读取: ' .. path:gsub('"', '') .. '"}')
            return
        end
    else
        f_test:close()
    end
    
    local safe_path = path:gsub("'", "'\\''")
    local tmp_out = "/tmp/ff_out_" .. os.time() .. math.random(100,999) .. ".txt"
    
    local cmd = string.format("V4L2_REQUEST_API=none LANG=C.UTF-8 /usr/bin/ffmpeg -threads 1 -hwaccel none -hide_banner -i '%s' > %s 2>&1", safe_path, tmp_out)
    os.execute(cmd)
    
    local f = io.open(tmp_out, "r")
    if not f then
        http.write('{"error":"ffmpeg 执行失败"}')
        return
    end
    local out = f:read("*a")
    f:close()
    os.remove(tmp_out)
    
    if not out or out == "" then
        http.write('{"error":"ffmpeg 未解析出内容"}')
        return
    end

    out = out:gsub("[\128-\255]", "") -- 过滤非 ASCII 字符
    
    local format_name = "Unknown"
    local fmt_m = out:match("Input #%d+, ([^,]+), from")
    if fmt_m then format_name = fmt_m end
    
    local duration = "0"
    local h, m, s = out:match("Duration: (%d+):(%d+):(%d+%.%d+)")
    if h then duration = tostring(math.floor(tonumber(h)*3600 + tonumber(m)*60 + tonumber(s))) end
    
    local bit_rate = out:match("bitrate: (%d+) kb/s") or "0"
    bit_rate = tostring(math.floor((tonumber(bit_rate) or 0) * 1000))

    local streams = {}
    for line in out:gmatch("[^\n]+") do
        if line:match("Stream #%d+:%d+.*: Video:") then
            local codec = line:match("Video: ([^,]+)") or "unknown"
            local w = line:match("(%d+)x(%d+)") or "0"
            local h_str = line:match("%d+x(%d+)") or "0"
            local fps = line:match("([%d%.]+) fps") or "0"
            local vbr = line:match("(%d+) kb/s") or "0"
            local pix = line:match("Video: .-, ([^,]+),") or ""
            
            -- ★ 核心修复 2：彻底抛弃 string.format，纯字符串拼接，绝不报错
            local s_obj = '{"codec_type":"video","codec_name":"' .. codec:gsub('"','') .. '","width":' .. w .. ',"height":' .. h_str .. ',"r_frame_rate":"' .. fps .. '/1","bit_rate":' .. tostring(math.floor((tonumber(vbr) or 0)*1000)) .. ',"pix_fmt":"' .. pix:gsub('"','') .. '"}'
            table.insert(streams, s_obj)
            
        elseif line:match("Stream #%d+:%d+.*: Audio:") then
            local codec = line:match("Audio: ([^%s]+)") or "unknown"
            local sr = line:match("(%d+) Hz") or "0"
            local layout = line:match("Hz, ([^,]+)") or ""
            local abr = line:match("(%d+) kb/s") or "0"
            local ch = "2"
            if layout:match("mono") then ch = "1" elseif layout:match("5%.1") then ch = "6" elseif layout:match("7%.1") then ch = "8" end
            
            local s_obj = '{"codec_type":"audio","codec_name":"' .. codec:gsub('"','') .. '","sample_rate":' .. sr .. ',"channels":' .. ch .. ',"channel_layout":"' .. layout:gsub('"','') .. '","bit_rate":' .. tostring(math.floor((tonumber(abr) or 0)*1000)) .. '}'
            table.insert(streams, s_obj)
        end
    end
    
    local s_json = "[" .. table.concat(streams, ",") .. "]"
    local final_json = '{"format":{"format_long_name":"' .. format_name:gsub('"','') .. '","format_name":"' .. format_name:gsub('"','') .. '","duration":' .. duration .. ',"bit_rate":' .. bit_rate .. '},"streams":' .. s_json .. '}'
        
    http.write(final_json)
end

-- ==========================================
-- 以下为 DLNA 投屏相关函数，保持原样
-- ==========================================
function dlna_discover() 
    local http = require "luci.http"
    local devices = {}
    local f = io.open("/tmp/dlna_devices.json", "r")
    if f then
        local content = f:read("*a")
        f:close()
        for url, name in content:gmatch('"url":"(.-)","name":"(.-)"') do table.insert(devices, {name = name, control_url = url}) end
    end
    http.prepare_content("application/json")
    http.write_json(devices)
end

function dlna_cast()
    local http = require "luci.http"
    local sys = require "luci.sys"
    local control_url = http.formvalue("control_url") or ""
    local video_url = http.formvalue("video_url") or ""
    if control_url == "" or video_url == "" then http.write_json({status = "error", message = "参数缺失"}); return end
    local soap1 = string.format([[<?xml version="1.0"?><s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/"><s:Body><u:SetAVTransportURI xmlns:u="urn:schemas-upnp-org:service:AVTransport:1"><InstanceID>0</InstanceID><CurrentURI>%s</CurrentURI><CurrentURIMetaData></CurrentURIMetaData></u:SetAVTransportURI></s:Body></s:Envelope>]], video_url)
    local soap2 = [[<?xml version="1.0"?><s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/"><s:Body><u:Play xmlns:u="urn:schemas-upnp-org:service:AVTransport:1"><InstanceID>0</InstanceID><Speed>1</Speed></u:Play></s:Body></s:Envelope>]]
    local cmd = string.format("curl -s -w '%%{http_code}' --connect-timeout 3 -X POST '%s' -H 'Content-Type: text/xml; charset=\"utf-8\"' -H 'SOAPAction: \"urn:schemas-upnp-org:service:AVTransport:1#SetAVTransportURI\"' -d '%s'", control_url, soap1:gsub("'", "'\\''"))
    local out1 = sys.exec(cmd)
    cmd = string.format("curl -s -w '%%{http_code}' --connect-timeout 3 -X POST '%s' -H 'Content-Type: text/xml; charset=\"utf-8\"' -H 'SOAPAction: \"urn:schemas-upnp-org:service:AVTransport:1#Play\"' -d '%s'", control_url, soap2:gsub("'", "'\\''"))
    local out2 = sys.exec(cmd)
    if out1 ~= "000" and out2 ~= "000" then http.write_json({status = "success"}) else http.write_json({status = "error", message = "无法连接设备"}) end
end

function dlna_cover()
    local http = require "luci.http"
    local sys = require "luci.sys"
    local title = http.formvalue("title") or ""
    local query = title:gsub("%[.-%]", ""):gsub("%(.-%)", ""):gsub("《.-》", ""):gsub("^%d+%s*", ""):gsub("^%s+", ""):gsub("%s+$", "")
    if query == "" then query = title end
    local cmd = string.format([[curl -s -G -k --connect-timeout 5 --max-time 10 'https://itunes.apple.com/search' --data-urlencode 'term=%s' --data-urlencode 'entity=song' --data-urlencode 'limit=1']], query:gsub("'", "'\\''"))
    local json_str = sys.exec(cmd)
    local artwork = json_str:match('"artworkUrl100":"([^"]+)"')
    if artwork then http.prepare_content("application/json"); http.write_json({status = "success", url = artwork:gsub("100x100", "600x600")}) else http.prepare_content("application/json"); http.write_json({status = "error", message = "未找到封面"}) end
end

function dlna_control()
    local http = require "luci.http"
    local sys = require "luci.sys"
    local action = http.formvalue("action") or ""
    local ctrl_url = http.formvalue("control_url") or ""
    local value = http.formvalue("value") or ""
    if action == "" or ctrl_url == "" then http.write_json({status = "error", message = "参数缺失"}); return end
    local target_url = ctrl_url
    local soap = ""
    if action == "pause" then soap = [[<?xml version="1.0"?><s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/"><s:Body><u:Pause xmlns:u="urn:schemas-upnp-org:service:AVTransport:1"><InstanceID>0</InstanceID></u:Pause></s:Body></s:Envelope>]]
    elseif action == "play" then soap = [[<?xml version="1.0"?><s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/"><s:Body><u:Play xmlns:u="urn:schemas-upnp-org:service:AVTransport:1"><InstanceID>0</InstanceID><Speed>1</Speed></u:Play></s:Body></s:Envelope>]]
    elseif action == "stop" then soap = [[<?xml version="1.0"?><s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/"><s:Body><u:Stop xmlns:u="urn:schemas-upnp-org:service:AVTransport:1"><InstanceID>0</InstanceID></u:Stop></s:Body></s:Envelope>]]
    elseif action == "seek" then soap = string.format([[<?xml version="1.0"?><s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/"><s:Body><u:Seek xmlns:u="urn:schemas-upnp-org:service:AVTransport:1"><InstanceID>0</InstanceID><Unit>REL_TIME</Unit><Target>%s</Target></u:Seek></s:Body></s:Envelope>]], value)
    elseif action == "volume" then 
        target_url = ctrl_url:gsub("AVTransport", "RenderingControl"):gsub("rendertransport", "rendercontrol")
        soap = string.format([[<?xml version="1.0"?><s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/"><s:Body><u:SetVolume xmlns:u="urn:schemas-upnp-org:service:RenderingControl:1"><InstanceID>0</InstanceID><Channel>Master</Channel><DesiredVolume>%s</DesiredVolume></u:SetVolume></s:Body></s:Envelope>]], value) 
    end
    if soap == "" then http.write_json({status = "error", message = "不支持的指令"}); return end
    local soap_action = "urn:schemas-upnp-org:service:AVTransport:1#" .. action:gsub("^%l", string.upper)
    if action == "volume" then soap_action = "urn:schemas-upnp-org:service:RenderingControl:1#SetVolume" end
    local cmd = string.format("curl -s -w '%%{http_code}' --connect-timeout 3 -X POST '%s' -H 'Content-Type: text/xml; charset=\"utf-8\"' -H 'SOAPAction: \"%s\"' -d '%s'", target_url, soap_action, soap:gsub("'", "'\\''"))
    local out = sys.exec(cmd)
    if out ~= "000" then http.write_json({status = "success", message = "指令已发送"}) else http.write_json({status = "error", message = "连接失败"}) end
end

function dlna_get_position()
    local http = require "luci.http"
    local sys = require "luci.sys"
    local ctrl_url = http.formvalue("control_url") or ""
    if ctrl_url == "" then http.write_json({status = "error", message = "缺少 control_url"}); return end
    local soap = [[<?xml version="1.0"?><s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/"><s:Body><u:GetPositionInfo xmlns:u="urn:schemas-upnp-org:service:AVTransport:1"><InstanceID>0</InstanceID></u:GetPositionInfo></s:Body></s:Envelope>]]
    local cmd = string.format("curl -s -w '%%{http_code}' --connect-timeout 1 --max-time 2 -X POST '%s' -H 'Content-Type: text/xml; charset=\"utf-8\"' -H 'SOAPAction: \"urn:schemas-upnp-org:service:AVTransport:1#GetPositionInfo\"' -d '%s'", ctrl_url, soap:gsub("'", "'\\''"))
    local out = sys.exec(cmd)
    local rel_time = out:match("<[rR]elTime>(.-)</[rR]elTime>")
    local track_duration = out:match("<[tT]rackDuration>(.-)</[tT]trackDuration>")
    local transport_state = out:match("<[tT]ransportState>(.-)</[tT]transportState>")
    if rel_time then http.prepare_content("application/json"); http.write_json({status = "success", rel_time = rel_time, duration = track_duration, state = transport_state}) else http.prepare_content("application/json"); http.write_json({status = "error", message = "设备未返回时间"}) end
end
