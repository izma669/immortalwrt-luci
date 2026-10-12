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

function browse_dir()
    local http = require "luci.http"
    local sys = require "luci.sys"
    local path = http.formvalue("path") or "/mnt"
    if not path:match("^/mnt") then path = "/mnt" end
    local safe = path:gsub("'", "'\\''")
    local out = sys.exec("ls -1p '" .. safe .. "' 2>/dev/null | grep '/$' | sed 's|/$||'")
    local dirs = {}
    for name in out:gmatch("[^\n]+") do table.insert(dirs, name) end
    local json = "["
    local first = true
    for _, name in ipairs(dirs) do
        if not first then json = json .. "," end
        json = json .. '"' .. name:gsub('"', '\\"') .. '"'
        first = false
    end
    json = json .. "]"
    http.prepare_content("application/json")
    http.write(json)
end

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

content = content:gsub("root%s+/www;", "__KEEP__/www;")
content = content:gsub("root%s+[^;]+;", "root " .. new_root .. ";")
content = content:gsub("__KEEP__/www;", "root /www;")

-- 新增：同步替换 /api/dir/ 的 alias 路径
local alias_root = new_root
if not alias_root:match("/$") then alias_root = alias_root .. "/" end
content = content:gsub("alias%s+[^;]+;", "alias " .. alias_root .. ";")

                f = io.open("/etc/nginx/media.locations", "w")
                if f then f:write(content); f:close() end
            end
        end
    end

    sys.exec("/etc/init.d/nginx reload")
    http.redirect(http.getenv("REQUEST_URI") or "/cgi-bin/luci/admin/services/nginx-manager")
end
