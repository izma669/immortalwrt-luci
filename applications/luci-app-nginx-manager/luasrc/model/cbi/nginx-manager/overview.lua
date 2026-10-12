local m, s, o
local uci = require "luci.model.uci".cursor()

m = Map("nginx", translate("Nginx 配置管理"),
    translate("直接管理 /etc/config/nginx 和 /etc/nginx/media.locations，操作立即生效。"))

-- ==================== 全局设置 ====================
s = m:section(NamedSection, "global", "main", translate("全局设置"))
s.anonymous = true
s.addremove = false

o = s:option(Flag, "uci_enable", translate("启用 UCI 配置"),
    translate("启用后 nginx 会根据 UCI 生成配置文件"))
o.default = "true"
o.rmempty = false

-- ==================== HTTP 服务（只读） ====================
s = m:section(NamedSection, "_lan_http", "server", translate("HTTP 服务（只读）"))
s.anonymous = true
s.addremove = false

o = s:option(DummyValue, "_http_listen", translate("监听地址"))
o.cfgvalue = function(self, section)
    return table.concat(uci:get_list("nginx", section, "listen") or {}, "  ")
end

o = s:option(DummyValue, "_http_name", translate("服务器名称"))
o.cfgvalue = function(self, section)
    return uci:get("nginx", section, "server_name") or "-"
end

-- ==================== HTTPS 服务（只读） ====================
s = m:section(NamedSection, "_lan", "server", translate("HTTPS 服务（只读）"))
s.anonymous = true
s.addremove = false

o = s:option(DummyValue, "_https_listen", translate("监听地址"))
o.cfgvalue = function(self, section)
    return table.concat(uci:get_list("nginx", section, "listen") or {}, "  ")
end

o = s:option(DummyValue, "_https_name", translate("服务器名称"))
o.cfgvalue = function(self, section)
    return uci:get("nginx", section, "server_name") or "-"
end

o = s:option(DummyValue, "_https_cert", translate("SSL 证书"))
o.cfgvalue = function(self, section)
    return uci:get("nginx", section, "ssl_certificate") or "-"
end

o = s:option(DummyValue, "_https_key", translate("SSL 私钥"))
o.cfgvalue = function(self, section)
    return uci:get("nginx", section, "ssl_certificate_key") or "-"
end

-- ==================== 媒体服务 ====================
s = m:section(NamedSection, "_media", "server", translate("媒体服务（可修改）"))
s.anonymous = true
s.addremove = false

o = s:option(DynamicList, "listen", translate("监听地址"),
    translate("例如 880 default_server"))
o.rmempty = false
o.datatype = "string"

-- 网站根目录：读/写 media.locations（非 UCI）
o = s:option(Value, "_root", translate("网站根目录"),
    translate("保存到 /etc/nginx/media.locations"))
o.default = "/mnt"
o.rmempty = false

-- 自定义读取：从 media.locations 找 location / { 里的 root
o.cfgvalue = function(self, section)
    local f = io.open("/etc/nginx/media.locations", "r")
    if not f then return "/mnt" end
    local content = f:read("*a")
    f:close()
    local in_root = false
    for line in content:gmatch("[^\n]+") do
        if line:match("^%s*location%s+/%s*{") then
            in_root = true
        elseif in_root then
            local r = line:match("^%s*root%s+([^;]+);")
            if r then return r end
            if line:match("^%s*}") then in_root = false end
        end
    end
    return "/mnt"
end

-- 自定义写入：只替换 location / 和视频正则里的 root，保护 /www
o.write = function(self, section, value)
    if not value or not value:match("^/") then return end
    local f = io.open("/etc/nginx/media.locations", "r")
    if not f then return end
    local content = f:read("*a")
    f:close()

    -- 先保护 player.html/mpegts.min.js 的 root /www
    content = content:gsub("root%s+/www;", "__KEEP__/www;")
    -- 替换其它所有 root
    content = content:gsub("root%s+[^;]+;", "root " .. value .. ";")
    -- 还原
    content = content:gsub("__KEEP__/www;", "root /www;")
    -- alias 也一起改（/api/dir/）
    content = content:gsub("alias%s+[^;]+;", "alias " .. value:gsub("/$", "") .. "/;")

    f = io.open("/etc/nginx/media.locations", "w")
    if f then
        f:write(content)
        f:close()
    end
end

-- ==================== 保存后自动重载 Nginx ====================
function m.on_after_commit(self)
    require("luci.sys").exec("/etc/init.d/nginx reload")
end

return m