module("luci.controller.nginx-manager", package.seeall)

function index()
    if not nixio.fs.access("/etc/config/nginx") then
        return
    end

    entry({"admin", "services", "nginx-manager"},
          cbi("nginx-manager/overview"),
          _("Nginx 管理器"), 30).leaf = true

    entry({"admin", "services", "nginx-manager", "browse"},
          call("browse_dir")).leaf = true

    entry({"admin", "services", "nginx-manager", "reload"},
          call("reload_nginx")).leaf = true
end

-- AJAX：列目录
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
    for i, name in ipairs(dirs) do
        if i > 1 then json = json .. "," end
        json = json .. '"' .. name:gsub('"', '\\"') .. '"'
    end
    json = json .. "]"
    http.prepare_content("application/json")
    http.write(json)
end

-- 一键重载
function reload_nginx()
    local sys = require "luci.sys"
    local http = require "luci.http"
    sys.exec("/etc/init.d/nginx reload")
    http.redirect(luci.dispatcher.build_url("admin", "services", "nginx-manager"))
end