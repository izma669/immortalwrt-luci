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
    entry({"dlna", "extract_audio"}, post("dlna_extract_audio")).leaf = true
    entry({"dlna", "get_progress"}, call("dlna_get_progress")).leaf = true
    entry({"dlna", "cancel_extract"}, post("dlna_cancel_extract")).leaf = true
    entry({"dlna", "check_task"}, post("dlna_check_task")).leaf = true
end

-------------------------------------------------------------------------------
-- 路径处理
--
-- 历史问题：下面所有接口都把 "/mnt" 写死成媒体根目录。旧机器 U 盘挂在 /mnt，
-- 所以能用；换到 x86 后盘挂在 /mnt/sda1，nginx 的 root/alias 改了，Lua 没改，
-- 于是 /media/xxx.mkv 被解析成 /mnt/media/xxx.mkv，必然“文件不存在”。
--
-- 现在改为自动解析根目录，顺序：
--   1) UCI: /etc/config/nginx-manager 里 config media 'media' / option root '/mnt/sda1'
--   2) /proc/mounts 中所有 /mnt/* 挂载点
--   3) /mnt 下实际存在的子目录
--   4) /mnt 兜底
-- 只要某个根目录下该文件真实存在就采用它，所以换盘、换挂载点都不用再改代码。
-------------------------------------------------------------------------------

local function unescape_file(s)
    return (s:gsub("%%(%x%x)", function(x) return string.char(tonumber(x, 16)) end))
end

-- 前端发送的是 encodeURIComponent(it.url)，而 it.url 本身已经是 encodeURIComponent 过的，
-- 所以这里是“二次编码 -> 两次解码”，两遍都要保留。
local function decode_file(raw)
    local f = unescape_file(raw or "")
    if f:match("%%") then f = unescape_file(f) end
    return f
end

local function file_exists(path)
    local f = io.open(path, "rb")
    if f then f:close(); return true end
    return false
end

local _media_roots
local function media_roots()
    if _media_roots then return _media_roots end
    local roots, seen = {}, {}

    local function add(p)
        if not p or p == "" then return end
        p = p:gsub("/+$", "")
        if p == "" then p = "/" end
        if not seen[p] then seen[p] = true; roots[#roots + 1] = p end
    end

    -- 1) UCI 显式指定
    local ok, uci = pcall(require, "luci.model.uci")
    if ok and uci then
        local ok2, cur = pcall(uci.cursor)
        if ok2 and cur then
            add(cur:get("nginx-manager", "media", "root"))
            add(cur:get("nginx-manager", "@media[0]", "root"))
        end
    end

    -- 2) /proc/mounts 里的 /mnt/* 挂载点（USB、移动硬盘、第二块盘）
    local mf = io.open("/proc/mounts", "r")
    if mf then
        for line in mf:lines() do
            local mp = line:match("^[^%s]+%s+(/[^%s]+)")
            if mp then
                mp = mp:gsub("\\040", " ")
                if mp:match("^/mnt/") then add(mp) end
            end
        end
        mf:close()
    end

    -- 3) 只是普通目录、不是挂载点的情况
    local p = io.popen("ls -1 /mnt 2>/dev/null")
    if p then
        for name in p:lines() do
            name = name:gsub("%s+$", "")
            if name ~= "" and name:sub(1, 1) ~= "." then add("/mnt/" .. name) end
        end
        p:close()
    end

    -- 4) 兜底
    add("/mnt")

    _media_roots = roots
    return roots
end

-- 把 URL 路径（/media/xxx）解析成真实文件路径；同时挡掉路径穿越
local function resolve_media(file)
    if not file or file == "" then return nil, "缺少 file 参数" end
    if file:find("%z") then return nil, "非法路径" end
    if file:sub(1, 1) ~= "/" then return nil, "非法路径：必须以 / 开头" end
    for seg in file:gmatch("[^/]+") do
        if seg == ".." then return nil, "非法路径" end
    end

    local roots = media_roots()
    for _, root in ipairs(roots) do
        local path = root .. file
        if file_exists(path) then return path end
    end
    return nil, "文件不存在: " .. file .. "（已尝试 " .. table.concat(roots, ", ") .. "）"
end

local function uri_encode_path(p)
    return (p:gsub("[^%w%-%._~/]", function(c) return string.format("%%%02X", c:byte()) end))
end

local function shell_quote(s)
    return "'" .. s:gsub("'", "'\\''") .. "'"
end

-------------------------------------------------------------------------------
-- 探测
-------------------------------------------------------------------------------

local function probe_with_ffprobe(path)
    if not file_exists("/usr/bin/ffprobe") then return nil end
    local cmd = string.format(
        "LANG=C.UTF-8 /usr/bin/ffprobe -v error -analyzeduration 50M -probesize 50M "
        .. "-print_format json -show_format -show_streams %s 2>/dev/null",
        shell_quote(path))
    local p = io.popen(cmd, "r")
    if not p then return nil end
    local out = p:read("*a")
    p:close()
    if not out or not out:match("^{") then return nil end
    -- 校验能被解析，避免把半截 JSON 丢给前端
    local ok, data = pcall(function() return require("luci.jsonc").parse(out) end)
    if not ok or type(data) ~= "table" or type(data.format) ~= "table" then return nil end
    return out
end

-- 没有 ffprobe 时退回解析 ffmpeg 日志（旧行为，字段少一些，但不会让功能直接不可用）
local function probe_with_ffmpeg(path)
    local tmp = string.format("/tmp/ffprobe_%d_%d.log", os.time(), math.random(1000, 9999))
    os.execute(string.format(
        "LANG=C.UTF-8 /usr/bin/ffmpeg -hide_banner -analyzeduration 50M -probesize 50M -i %s > %s 2>&1",
        shell_quote(path), shell_quote(tmp)))

    local f = io.open(tmp, "r")
    if not f then return nil end
    local out = f:read("*a")
    f:close()
    os.remove(tmp)
    if not out or out == "" then return nil end

    local data = { format = {}, streams = {} }
    local fmt = out:match("Input #%d+, ([^,]+),") or out:match("Input #%d+, (.+), from")
    data.format.format_name = fmt or ""
    data.format.format_long_name = fmt or ""

    local h, m, s = out:match("Duration: (%d+):(%d+):(%d+%.%d+)")
    data.format.duration = h and tostring(math.floor(tonumber(h) * 3600 + tonumber(m) * 60 + tonumber(s))) or "0"
    local br = out:match("bitrate: (%d+) kb/s")
    data.format.bit_rate = br and tostring(tonumber(br) * 1000) or "0"

    for line in out:gmatch("[^\r\n]+") do
        local sidx = tonumber(line:match("Stream #%d+:(%d+)"))
        local is_default = line:match("%(default%)") and 1 or 0
        if line:match("Stream #%d+:%d+.*: Video:") then
            local codec = line:match("Video: ([^,]+)") or "unknown"
            local w, hh = line:match("(%d+)x(%d+)")
            local fps = line:match("([%d%.]+) fps")
            local vbr = line:match("(%d+) kb/s")
            local pix = line:match("Video: .-, ([%w_]+)")
            table.insert(data.streams, {
                index = sidx,
                codec_type = "video",
                codec_name = codec,
                width = tonumber(w) or 0,
                height = tonumber(hh) or 0,
                r_frame_rate = fps and (fps .. "/1") or "0/1",
                bit_rate = vbr and tostring(tonumber(vbr) * 1000) or "0",
                pix_fmt = pix or "",
                disposition = {
                    default = is_default,
                    attached_pic = line:match("attached pic") and 1 or 0
                }
            })
        elseif line:match("Stream #%d+:%d+.*: Audio:") then
            local codec = line:match("Audio: ([^%s,]+)") or "unknown"
            local sr = line:match("(%d+) Hz")
            local layout = line:match("Hz, ([^,]+)")
            local abr = line:match("(%d+) kb/s")
            local ch = 2
            if layout then
                if layout:match("mono") then ch = 1
                elseif layout:match("5%.1") then ch = 6
                elseif layout:match("7%.1") then ch = 8 end
            end
            table.insert(data.streams, {
                index = sidx,
                codec_type = "audio",
                codec_name = codec,
                sample_rate = sr and tostring(sr) or "0",
                channels = ch,
                channel_layout = layout or "",
                bit_rate = abr and tostring(tonumber(abr) * 1000) or "0",
                disposition = { default = is_default }
            })
        end
    end

    return require("luci.jsonc").stringify(data)
end

-- 返回首个真实视频流的编码名（跳过内嵌封面 attached_pic）
--   "none"    纯音频
--   "unknown" ffprobe 不可用，按“可直拷”处理
local function probe_video_codec(path)
    local out = probe_with_ffprobe(path)
    if not out then return "unknown" end
    local ok, data = pcall(function() return require("luci.jsonc").parse(out) end)
    if not ok or type(data) ~= "table" or type(data.streams) ~= "table" then return "unknown" end
    for _, s in ipairs(data.streams) do
        if s.codec_type == "video" then
            local disp = s.disposition or {}
            local pic = disp.attached_pic
            if pic ~= 1 and pic ~= true then
                return s.codec_name or "unknown"
            end
        end
    end
    return "none"
end

local function has_encoder(name)
    local f = io.popen("/usr/bin/ffmpeg -hide_banner -encoders 2>/dev/null")
    if not f then return false end
    local out = f:read("*a") or ""
    f:close()
    return out:find("%s" .. name .. "%s") ~= nil
end

function dlna_ffprobe()
    local http = require "luci.http"
    local jsonc = require "luci.jsonc"
    http.prepare_content("application/json")

    local file = decode_file(http.formvalue("file"))
    local path, err = resolve_media(file)
    if not path then http.write(jsonc.stringify({ error = err })); return end

    local out = probe_with_ffprobe(path) or probe_with_ffmpeg(path)
    if not out then
        http.write(jsonc.stringify({ error = "无法解析该文件（ffprobe / ffmpeg 都没有返回有效结果）" }))
        return
    end
    http.write(out)
end

-------------------------------------------------------------------------------
-- 转封装 / 转码
-- 前端传 plan：
--   {"container":"mp4","streams":[{"index":0,"type":"video","action":"copy"},
--                                 {"index":1,"type":"audio","action":"aac2"}]}
-- 处理方式：copy / ignore / aac2 / aac51 / ac351（视频只允许 copy、ignore）
-- 没有 plan 时退回旧行为：视频直拷 + 首条音轨转 AAC 2CH
-------------------------------------------------------------------------------

local ACODEC_SPEC =
{
    aac2  = { codec = "aac", br = "192k", ac = 2 },
    aac51 = { codec = "aac", br = "384k", ac = 6 },
    ac351 = { codec = "ac3", br = "640k", ac = 6 }
}

local function build_plan_args(plan, container)
    local args = {}
    local ov, oa, osn = 0, 0, 0
    local audio_out = {}

    for _, s in ipairs(plan.streams) do
        local idx = tonumber(s.index)
        local typ = tostring(s.type or "")
        local copy = (s.copy == true)
        local trans = tostring(s.transcode or "none")

        if idx and idx >= 0 then
            if typ == "video" then
                if copy then
                    args[#args + 1] = string.format("-map 0:%d -c:v:%d copy", idx, ov)
                    ov = ov + 1
                end
            elseif typ == "audio" then
                -- 同一条源音轨可以先复制原轨、再转一份，这是 #4 的关键
                if copy then
                    args[#args + 1] = string.format("-map 0:%d -c:a:%d copy", idx, oa)
                    audio_out[#audio_out + 1] = { oi = oa, trans = false }
                    oa = oa + 1
                end
                if ACODEC_SPEC[trans] then
                    local spec = ACODEC_SPEC[trans]
                    args[#args + 1] = string.format(
                        "-map 0:%d -c:a:%d %s -b:a:%d %s -ac:a:%d %d",
                        idx, oa, spec.codec, oa, spec.br, oa, spec.ac)
                    audio_out[#audio_out + 1] = { oi = oa, trans = true }
                    oa = oa + 1
                end
            elseif typ == "subtitle" then
                -- mpegts 不支持文本字幕：TS 下忽略；MP4 里转 mov_text
                if copy and container == "mp4" then
                    args[#args + 1] = string.format("-map 0:%d -c:s:%d mov_text", idx, osn)
                    osn = osn + 1
                end
            end
        end
    end

    -- 有转码音轨时，把转码轨设为 default，保证浏览器默认出声；
    -- 原轨仍然保留且可被电视手动选择
    local has_trans = false
    for _, a in ipairs(audio_out) do if a.trans then has_trans = true end end
    if has_trans then
        for _, a in ipairs(audio_out) do
            args[#args + 1] = string.format("-disposition:a:%d %s", a.oi, a.trans and "default" or "0")
        end
    end

    return table.concat(args, " "), (ov + oa + osn)
end

function dlna_extract_audio()
    local http = require "luci.http"
    local sys = require "luci.sys"
    local jsonc = require "luci.jsonc"
    http.prepare_content("application/json")

    local file = decode_file(http.formvalue("file"))
    local path, err = resolve_media(file)
    if not path then http.write(jsonc.stringify({ error = err })); return end

    local container = "mp4"
    local args, nstream, plan_seen = nil, 0, false

    local plan_raw = http.formvalue("plan")
    if plan_raw and plan_raw ~= "" then
        local ok, plan = pcall(function() return jsonc.parse(plan_raw) end)
        if ok and type(plan) == "table" and type(plan.streams) == "table" then
            plan_seen = true
            if plan.container == "ts" then container = "ts" end
            args, nstream = build_plan_args(plan, container)
        end
    end

    if plan_seen then
        -- 明确给了 plan：全忽略就报错，不要偷偷套默认值
        if nstream == 0 or not args or args == "" then
            http.write(jsonc.stringify({ error = "没有选择任何要保留的数据流" }))
            return
        end
    else
        -- 旧前端（没有 plan）：视频直拷 + 首条音轨 AAC 2CH
        args = "-map 0:v:0? -c:v copy -map 0:a:0? -c:a aac -b:a 192k -ac 2"
    end

    local ext = (container == "ts") and ".ts" or ".mp4"
    local dir = path:match("^(.*)/[^/]+$") or "/mnt"
    local orig_name = path:match("([^/]+)$") or "media"
    local base_name = orig_name:gsub("%.[^.]+$", ""):gsub("[%c/]", "_")
    local token = tostring(os.time()) .. tostring(math.random(100, 999))
    local new_name = base_name .. "_TRANS_" .. token .. ext
    local out_file = dir .. "/" .. new_name

    -- 返回给前端的 URL：保留原目录（URL 形式），文件名做百分号编码
    local url_dir = file:gsub("([^/]+)$", "")
    local new_url = uri_encode_path(url_dir .. new_name)

    local prog_file = "/tmp/aac_" .. token .. ".prog"
    local log_file = "/tmp/aac_" .. token .. ".log"
    local meta_file = "/tmp/aac_" .. token .. ".meta"

    -- 同一源文件的旧任务元数据清掉，避免旧输出（如之前的纯音频 .ts）被当成当前任务
    local old = io.popen("ls /tmp/aac_*.meta 2>/dev/null")
    if old then
        for mline in old:lines() do
            local of = io.open(mline, "r")
            if of then
                local s0 = of:read("*l")
                of:close()
                if s0 == file then os.remove(mline) end
            end
        end
        old:close()
    end

    -- 元数据用于刷新页面后找回任务
    local mf = io.open(meta_file, "w")
    if mf then
        mf:write(file, "\n", new_url, "\n")
        mf:close()
    end

    sys.exec("pkill -f 'TRANS_" .. token .. "' 2>/dev/null")

    local tail
    if container == "ts" then
        tail = "-f mpegts"
    else
        tail = "-avoid_negative_ts make_zero -movflags +faststart -f mp4"
    end

    local cmd = string.format(
        "(LANG=C.UTF-8 /usr/bin/ffmpeg -hide_banner -analyzeduration 50M -probesize 50M "
        .. "-i %s %s %s %s -progress %s > %s 2>&1) &",
        shell_quote(path), args, tail, shell_quote(out_file), shell_quote(prog_file), shell_quote(log_file))
    os.execute(cmd)

    http.write('{"status":"success","token":"' .. token .. '","new_file_url":' .. jsonc.stringify(new_url)
        .. ',"container":"' .. container .. '","args":' .. jsonc.stringify(args) .. '}')
end

function dlna_check_task()
    local http = require "luci.http"
    local sys = require "luci.sys"
    local file = decode_file(http.formvalue("file"))
    http.prepare_content("application/json")

    if file == "" then http.write('{"status":"none"}'); return end

    -- 只认“正在运行”的任务：任务完成后输出文件已经在目录里，
    -- 再自动接管播放只会让旧任务（比如以前那个纯音频 .ts）劫持原视频。
    local p = io.popen("ls -t /tmp/aac_*.meta 2>/dev/null")
    if p then
        for line in p:lines() do
            local token = line:match("aac_(%d+)%.meta")
            if token then
                local mf = io.open(line, "r")
                if mf then
                    local src = mf:read("*l")
                    local out_name = mf:read("*l")
                    mf:close()
                    if src == file and out_name and sys.call("pgrep -f 'TRANS_" .. token .. "'") == 0 then
                        p:close()
                        http.write_json({ status = "found", token = token, new_file_url = out_name, is_done = false })
                        return
                    end
                end
            end
        end
        p:close()
    end
    http.write('{"status":"none"}')
end

function dlna_get_progress()
    local http = require "luci.http"
    local token = (http.formvalue("token") or ""):gsub("%D", "")
    http.prepare_content("application/json")

    if token == "" then http.write('{"error":"缺少 token"}'); return end

    local prog_file = "/tmp/aac_" .. token .. ".prog"
    local log_file = "/tmp/aac_" .. token .. ".log"
    local f = io.open(prog_file, "r")

    if not f then
        local is_running = require("luci.sys").call("pgrep -f 'TRANS_" .. token .. "'") == 0
        if is_running then
            http.write('{"status":"starting"}')
        else
            local err_msg = "未知错误"
            local f_log = io.open(log_file, "r")
            if f_log then
                local log_content = f_log:read("*a")
                f_log:close()
                err_msg = log_content:sub(-300)
                err_msg = err_msg:gsub("[\128-\255]", ""):gsub("\n", " ")
            end
            http.write('{"status":"error","message":"FFmpeg 进程意外退出","log":' .. require("luci.jsonc").stringify(err_msg) .. '}')
        end
        return
    end

    local content = f:read("*a")
    f:close()

    -- -progress 是逐块追加写的：必须取“最后一次”的值，
    -- 用 match() 只会拿到第一块，表现就是进度条一直不动。
    local out_time_us, speed_str, total_size = 0, "0x", 0
    for v in content:gmatch("out_time_us=(%d+)") do out_time_us = tonumber(v) or 0 end
    for v in content:gmatch("total_size=(%d+)") do total_size = tonumber(v) or 0 end
    for v in content:gmatch("speed=%s*([%d%.x]+)") do speed_str = v end

    local is_end = false
    if content:match("progress=end") then is_end = true end

    local loadavg = "0.00"
    local f_load = io.open("/proc/loadavg", "r")
    if f_load then
        local load_str = f_load:read("*l")
        if load_str then loadavg = load_str:match("^(%S+)") or "0.00" end
        f_load:close()
    end

    if is_end then
        http.write('{"status":"done","out_time_us":' .. out_time_us .. ',"total_size":' .. total_size
            .. ',"speed":"' .. speed_str .. '","load":"' .. loadavg .. '"}')
    else
        http.write('{"status":"running","out_time_us":' .. out_time_us .. ',"total_size":' .. total_size
            .. ',"speed":"' .. speed_str .. '","load":"' .. loadavg .. '"}')
    end
end

function dlna_cancel_extract()
    local http = require "luci.http"
    local token = (http.formvalue("token") or ""):gsub("%D", "")
    local new_url = decode_file(http.formvalue("new_url"))
    http.prepare_content("application/json")

    if token == "" then http.write('{"error":"缺少 token"}'); return end

    require("luci.sys").exec("pkill -f 'TRANS_" .. token .. "'; rm -f /tmp/aac_" .. token .. ".*")

    if new_url ~= "" then
        local path = resolve_media(new_url)
        if path then os.remove(path) end
    end
    http.write('{"status":"success"}')
end

-------------------------------------------------------------------------------
-- DLNA
-------------------------------------------------------------------------------

function dlna_discover()
    local http = require "luci.http"
    local devices = {}
    local f = io.open("/tmp/dlna_devices.json", "r")
    if f then
        local content = f:read("*a")
        f:close()
        for url, name in content:gmatch('"url":"(.-)","name":"(.-)"') do
            table.insert(devices, { name = name, control_url = url })
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
    if control_url == "" or video_url == "" then http.write_json({ status = "error", message = "参数缺失" }); return end

    local soap1 = string.format([[<?xml version="1.0"?><s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/"><s:Body><u:SetAVTransportURI xmlns:u="urn:schemas-upnp-org:service:AVTransport:1"><InstanceID>0</InstanceID><CurrentURI>%s</CurrentURI><CurrentURIMetaData></CurrentURIMetaData></u:SetAVTransportURI></s:Body></s:Envelope>]], video_url)
    local soap2 = [[<?xml version="1.0"?><s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/"><s:Body><u:Play xmlns:u="urn:schemas-upnp-org:service:AVTransport:1"><InstanceID>0</InstanceID><Speed>1</Speed></u:Play></s:Body></s:Envelope>]]

    local cmd = string.format("curl -s -w '%%{http_code}' --connect-timeout 3 -X POST '%s' -H 'Content-Type: text/xml; charset=\"utf-8\"' -H 'SOAPAction: \"urn:schemas-upnp-org:service:AVTransport:1#SetAVTransportURI\"' -d '%s'", control_url, soap1:gsub("'", "'\\''"))
    local out1 = sys.exec(cmd)
    cmd = string.format("curl -s -w '%%{http_code}' --connect-timeout 3 -X POST '%s' -H 'Content-Type: text/xml; charset=\"utf-8\"' -H 'SOAPAction: \"urn:schemas-upnp-org:service:AVTransport:1#Play\"' -d '%s'", control_url, soap2:gsub("'", "'\\''"))
    local out2 = sys.exec(cmd)

    if out1 ~= "000" and out2 ~= "000" then
        http.write_json({ status = "success" })
    else
        http.write_json({ status = "error", message = "无法连接设备" })
    end
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
    if artwork then
        http.prepare_content("application/json")
        http.write_json({ status = "success", url = artwork:gsub("100x100", "600x600") })
    else
        http.prepare_content("application/json")
        http.write_json({ status = "error", message = "未找到封面" })
    end
end

function dlna_control()
    local http = require "luci.http"
    local sys = require "luci.sys"
    local action = http.formvalue("action") or ""
    local ctrl_url = http.formvalue("control_url") or ""
    local value = http.formvalue("value") or ""
    if action == "" or ctrl_url == "" then http.write_json({ status = "error", message = "参数缺失" }); return end

    local target_url = ctrl_url
    local soap = ""
    if action == "pause" then
        soap = [[<?xml version="1.0"?><s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/"><s:Body><u:Pause xmlns:u="urn:schemas-upnp-org:service:AVTransport:1"><InstanceID>0</InstanceID></u:Pause></s:Body></s:Envelope>]]
    elseif action == "play" then
        soap = [[<?xml version="1.0"?><s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/"><s:Body><u:Play xmlns:u="urn:schemas-upnp-org:service:AVTransport:1"><InstanceID>0</InstanceID><Speed>1</Speed></u:Play></s:Body></s:Envelope>]]
    elseif action == "stop" then
        soap = [[<?xml version="1.0"?><s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/"><s:Body><u:Stop xmlns:u="urn:schemas-upnp-org:service:AVTransport:1"><InstanceID>0</InstanceID></u:Stop></s:Body></s:Envelope>]]
    elseif action == "seek" then
        soap = string.format([[<?xml version="1.0"?><s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/"><s:Body><u:Seek xmlns:u="urn:schemas-upnp-org:service:AVTransport:1"><InstanceID>0</InstanceID><Unit>REL_TIME</Unit><Target>%s</Target></u:Seek></s:Body></s:Envelope>]], value)
    elseif action == "volume" then
        target_url = ctrl_url:gsub("AVTransport", "RenderingControl"):gsub("rendertransport", "rendercontrol")
        soap = string.format([[<?xml version="1.0"?><s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/"><s:Body><u:SetVolume xmlns:u="urn:schemas-upnp-org:service:RenderingControl:1"><InstanceID>0</InstanceID><Channel>Master</Channel><DesiredVolume>%s</DesiredVolume></u:SetVolume></s:Body></s:Envelope>]], value)
    end
    if soap == "" then http.write_json({ status = "error", message = "不支持的指令" }); return end

    local soap_action = "urn:schemas-upnp-org:service:AVTransport:1#" .. action:gsub("^%l", string.upper)
    if action == "volume" then soap_action = "urn:schemas-upnp-org:service:RenderingControl:1#SetVolume" end

    local cmd = string.format("curl -s -w '%%{http_code}' --connect-timeout 3 -X POST '%s' -H 'Content-Type: text/xml; charset=\"utf-8\"' -H 'SOAPAction: \"%s\"' -d '%s'", target_url, soap_action, soap:gsub("'", "'\\''"))
    local out = sys.exec(cmd)

    if out ~= "000" then
        http.write_json({ status = "success", message = "指令已发送" })
    else
        http.write_json({ status = "error", message = "连接失败" })
    end
end

function dlna_get_position()
    local http = require "luci.http"
    local sys = require "luci.sys"
    local ctrl_url = http.formvalue("control_url") or ""
    if ctrl_url == "" then http.write_json({ status = "error", message = "缺少 control_url" }); return end

    local soap = [[<?xml version="1.0"?><s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/"><s:Body><u:GetPositionInfo xmlns:u="urn:schemas-upnp-org:service:AVTransport:1"><InstanceID>0</InstanceID></u:GetPositionInfo></s:Body></s:Envelope>]]
    local cmd = string.format("curl -s -w '%%{http_code}' --connect-timeout 1 --max-time 2 -X POST '%s' -H 'Content-Type: text/xml; charset=\"utf-8\"' -H 'SOAPAction: \"urn:schemas-upnp-org:service:AVTransport:1#GetPositionInfo\"' -d '%s'", ctrl_url, soap:gsub("'", "'\\''"))
    local out = sys.exec(cmd)

    local rel_time = out:match("<[rR]elTime>(.-)</[rR]elTime>")
    local track_duration = out:match("<[tT]rackDuration>(.-)</[tT]rackDuration>")
    local transport_state = out:match("<[tT]ransportState>(.-)</[tT]ransportState>")

    if rel_time then
        http.prepare_content("application/json")
        http.write_json({ status = "success", rel_time = rel_time, duration = track_duration, state = transport_state })
    else
        http.prepare_content("application/json")
        http.write_json({ status = "error", message = "设备未返回时间" })
    end
end
