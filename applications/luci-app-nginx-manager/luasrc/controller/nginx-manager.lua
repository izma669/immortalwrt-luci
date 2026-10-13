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
end

-- AJAX 目录浏览
function browse_dir()
    local http = require "luci.http"
    local sys = require "luci.sys"
    local path = http.formvalue("path") or "/mnt"
    
    -- 安全校验：只允许 /mnt 开头的路径
    if not path:match("^/mnt") then path = "/mnt" end
    local safe = path:gsub("'", "'\\''")
    
    local out = sys.exec("ls -1p '" .. safe .. "' 2>/dev/null | grep '/$' | sed 's|/$||'")
    local dirs = {}
    for name in out:gmatch("[^\n]+") do 
        table.insert(dirs, name) 
    end
    
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
    -- 防止 gsub 替换时把 % 当作转义符
    alias_dir = alias_dir:gsub("%%", "%%%%")
    local safe_root = root_dir:gsub("%%", "%%%%")
    
    return string.format([[
server {
    listen %s default_server;
    listen [::]:%s default_server;
    server_name _lan;

    # 播放器静态文件
    location = /player.html {
        root /www;
    }
    location = /mpegts.min.js {
        root /www;
    }

    # 目录列表 API（供 player.html 调用）
    location /api/dir/ {
        alias %s;
        autoindex on;
        autoindex_format json;
        autoindex_exact_size on;
    }

    # 媒体文件流式传输（支持拖动进度条）
    location ~* \.(mp4|webm|mkv|mov|avi|m4v|ogv|flv|3gp|ts|m2ts|wmv|mp3|m4a|flac|aac|ogg|wav)$ {
        root %s;
        add_header Accept-Ranges bytes;
        add_header Cache-Control "public, max-age=3600";
    }

    # 默认根目录，找不到文件回退到 player.html
    location / {
        root %s;
        try_files $uri /player.html;
    }
}
]], port, port, alias_dir, safe_root, safe_root)
end

-- 保存逻辑
function do_save()
    local http = require "luci.http"
    local sys = require "luci.sys"
    local action = http.formvalue("action") or ""

    local port, root_dir = get_current_media_config()

    if action == "change_port" then
        local new_port = http.formvalue("new_port")
        if new_port and new_port:match("^%d+$") then
            port = new_port
        end
    elseif action == "change_root" then
        local new_root = http.formvalue("new_root")
        if new_root and new_root:match("^/") then
            root_dir = new_root
        end
    end

    -- 生成并写入独立的 media.conf
    local conf = generate_media_conf(port, root_dir)
    local f = io.open("/etc/nginx/conf.d/media.conf", "w")
    if f then
        f:write(conf)
        f:close()
    end

    -- 清理旧文件
    os.remove("/etc/nginx/media.locations")

    -- 清理 UCI 中残留的媒体服务，绝对不碰 80 和 443
    sys.exec("uci -q delete nginx._media")
    sys.exec("uci commit nginx")

    -- 重载 Nginx
    sys.exec("/etc/init.d/nginx reload")
    http.redirect(http.getenv("REQUEST_URI") or "/cgi-bin/luci/admin/services/nginx-manager")
end
