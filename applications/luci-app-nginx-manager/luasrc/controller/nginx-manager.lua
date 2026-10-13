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
    
    -- 防止命令注入
    local safe = path:gsub("'", "'\\''")
    
    local out = sys.exec("ls -1p '" .. safe .. "' 2>/dev/null | grep '/$' | sed 's|/$||'")
    local dirs = {}
    for name in out:gmatch("[^\n]+") do 
        table.insert(dirs, name) 
    end
    
    http.prepare_content("application/json")
    http.write_json(dirs)
end

-- 保存配置逻辑
function do_save()
    local http = require "luci.http"
    local sys = require "luci.sys"
    local action = http.formvalue("action") or ""

    if action == "change_port" then
        local new_port = http.formvalue("new_port")
        if new_port and new_port:match("^%d+$") then
            local mn = http.formvalue("media_name") or "_media"
            sys.exec("uci -q delete nginx." .. mn .. ".listen")
            sys.exec('uci add_list nginx.' .. mn .. '.listen="' .. new_port .. ' default_server"')
            sys.exec('uci add_list nginx.' .. mn .. '.listen="[::]:' .. new_port .. ' default_server"')
            sys.exec("uci commit nginx")
        end
    elseif action == "change_root" then
        local new_root = http.formvalue("new_root")
        if new_root and new_root:match("^/") then
            local f = io.open("/etc/nginx/media.locations", "r")
            if f then
                local content = f:read("*a")
                f:close()
                
                -- 保护 /www 静态资源路径不被替换
                content = content:gsub("root%s+/www;", "___WWW_PLACEHOLDER___")
                content = content:gsub("root%s+[^;]+;", "root " .. new_root .. ";")
                content = content:gsub("___WWW_PLACEHOLDER___", "root /www;")
                
                -- 同步替换 /api/dir/ 的 alias
                local alias_root = new_root
                if not alias_root:match("/$") then alias_root = alias_root .. "/" end
                -- 转义 gsub 替换字符串中的 % 字符，防止崩溃
                alias_root = alias_root:gsub("%%", "%%%%")
                content = content:gsub("alias%s+[^;]+;", "alias " .. alias_root .. ";")
                
                f = io.open("/etc/nginx/media.locations", "w")
                if f then 
                    f:write(content)
                    f:close() 
                end
            end
        end
    end

    sys.exec("/etc/init.d/nginx reload")
    http.redirect(http.getenv("REQUEST_URI") or "/cgi-bin/luci/admin/services/nginx-manager")
end