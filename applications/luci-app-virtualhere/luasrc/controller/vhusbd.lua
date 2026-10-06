module("luci.controller.vhusbd", package.seeall)

function index()
    entry({"admin", "services", "vhusbd"}, template("vhusbd/status"), _("VirtualHere"), 60)
    entry({"admin", "services", "vhusbd", "action"}, call("action_dispatch")).leaf = true
end

-- 辅助函数：恢复保存的防火墙状态
local function restore_fw()
    local fs = require "nixio.fs"
    local state_file = "/etc/config/vhusbd_fw_state"
    if fs.access(state_file) then
        local content = fs.readfile(state_file)
        local wan_state = content:match("WAN=(%d)") or "0"
        local ipv6_state = content:match("IPV6=(%d)") or "0"
        
        if wan_state == "1" then
            luci.sys.exec("iptables -D INPUT -p tcp --dport 7575 -j ACCEPT 2>/dev/null")
            luci.sys.exec("iptables -I INPUT -p tcp --dport 7575 -j ACCEPT 2>/dev/null")
        end
        if ipv6_state == "1" then
            luci.sys.exec("ip6tables -D INPUT -p tcp --dport 7575 -j ACCEPT 2>/dev/null")
            luci.sys.exec("ip6tables -I INPUT -p tcp --dport 7575 -j ACCEPT 2>/dev/null")
        end
    end
end

function action_dispatch()
    local action = luci.http.formvalue("action")
    local out = "ERROR:未知操作"

    if action == "status" then
        local s = luci.sys.exec("ps | grep '[v]husbd' | grep -v 'Z' | wc -l"):gsub("%s+", "")
        out = (tonumber(s) > 0) and "RUNNING" or "STOPPED"

    elseif action == "start" then
        luci.sys.exec("/etc/init.d/vhusbd start >/dev/null 2>&1")
        restore_fw() -- 启动时自动恢复防火墙状态
        out = "SUCCESS:服务已启动，网络访问状态已恢复"
    elseif action == "stop" then
        luci.sys.exec("/etc/init.d/vhusbd stop >/dev/null 2>&1")
        luci.sys.exec("killall -9 vhusbd >/dev/null 2>&1")
        luci.sys.exec("iptables -D INPUT -p tcp --dport 7575 -j ACCEPT 2>/dev/null")
        luci.sys.exec("ip6tables -D INPUT -p tcp --dport 7575 -j ACCEPT 2>/dev/null")
        out = "SUCCESS:服务已停止，为安全起见已暂时关闭网络访问"
    elseif action == "restart" then
        luci.sys.exec("/etc/init.d/vhusbd restart >/dev/null 2>&1")
        restore_fw()
        out = "SUCCESS:服务已重启，网络访问状态已恢复"

    elseif action == "get_name" then
        local fs = require "nixio.fs"
        local filepath = "/usr/bin/config.ini"
        if fs.access(filepath) then
            local content = fs.readfile(filepath)
            local name = content:match("ServerName=([^\n]*)")
            out = name and ("NAME:" .. name) or "NAME:"
        else
            out = "NAME:"
        end

    elseif action == "rename" then
        local name = luci.http.formvalue("name")
        if not name or name == "" then
            out = "ERROR:名称不能为空"
        else
            name = name:gsub("[\r\n]", "")
            local fs = require "nixio.fs"
            local filepath = "/usr/bin/config.ini"
            if not fs.access(filepath) then
                out = "ERROR:配置文件 " .. filepath .. " 不存在"
            else
                local content = fs.readfile(filepath)
                if content:match("ServerName=") then
                    content = content:gsub("ServerName=[^\n]*", "ServerName=" .. name)
                else
                    content = content .. "\nServerName=" .. name
                end
                fs.writefile(filepath, content)
                luci.sys.exec("/etc/init.d/vhusbd restart >/dev/null 2>&1")
                restore_fw()
                out = "SUCCESS:服务器已重命名为 " .. name .. " 并已重启"
            end
        end

    elseif action == "register" then
        local ifname = luci.sys.exec("uci -q get network.lan.ifname 2>/dev/null"):gsub("\n", "")
        if ifname == "" then ifname = "br-lan" end
        local mac = luci.sys.exec("cat /sys/class/net/" .. ifname .. "/address 2>/dev/null"):gsub("[:\n%s]", ""):lower()
        if #mac ~= 12 then
            mac = luci.sys.exec("cat /sys/class/net/eth0/address 2>/dev/null"):gsub("[:\n%s]", ""):lower()
        end
        if #mac ~= 12 then
            out = "ERROR:无法获取有效 MAC 地址"
        else
            local cmd = string.format("sed -i 's/^License=.\\{12\\},/License=%s,/' /usr/bin/config.ini", mac)
            luci.sys.exec(cmd)
            out = "SUCCESS:注册成功！序列号: " .. mac
        end

    elseif action == "get_fw" then
        local wan_on = luci.sys.exec("iptables -C INPUT -p tcp --dport 7575 -j ACCEPT >/dev/null 2>&1 && echo 1 || echo 0"):gsub("\n", "")
        local ipv6_on = luci.sys.exec("ip6tables -C INPUT -p tcp --dport 7575 -j ACCEPT >/dev/null 2>&1 && echo 1 || echo 0"):gsub("\n", "")
        out = "FW:" .. wan_on .. "," .. ipv6_on

    elseif action == "set_fw" then
        local fw_type = luci.http.formvalue("type")
        local fw_val = luci.http.formvalue("val")
        local port = "7575"
        
        if fw_type == "wan" then
            luci.sys.exec("iptables -D INPUT -p tcp --dport " .. port .. " -j ACCEPT 2>/dev/null")
            if fw_val == "1" then
                luci.sys.exec("iptables -I INPUT -p tcp --dport " .. port .. " -j ACCEPT 2>/dev/null")
                out = "SUCCESS:外网访问已开启"
            else
                out = "SUCCESS:外网访问已关闭"
            end
        elseif fw_type == "ipv6" then
            luci.sys.exec("ip6tables -D INPUT -p tcp --dport " .. port .. " -j ACCEPT 2>/dev/null")
            if fw_val == "1" then
                luci.sys.exec("ip6tables -I INPUT -p tcp --dport " .. port .. " -j ACCEPT 2>/dev/null")
                out = "SUCCESS:IPv6 访问已开启"
            else
                out = "SUCCESS:IPv6 访问已关闭"
            end
        end
        
        -- 记录用户偏好到状态文件
        local fs = require "nixio.fs"
        local state_file = "/etc/config/vhusbd_fw_state"
        local wan_state = "0"
        local ipv6_state = "0"
        if fs.access(state_file) then
            local content = fs.readfile(state_file)
            wan_state = content:match("WAN=(%d)") or "0"
            ipv6_state = content:match("IPV6=(%d)") or "0"
        end
        if fw_type == "wan" then wan_state = fw_val end
        if fw_type == "ipv6" then ipv6_state = fw_val end
        fs.writefile(state_file, "WAN=" .. wan_state .. "\nIPV6=" .. ipv6_state .. "\n")

    elseif action == "logs" then
        out = luci.sys.exec("logread | grep -i vhusbd | tail -n 50")
        if out == "" then out = "暂无日志信息" end
    end

    luci.http.prepare_content("text/plain")
    luci.http.write(out)
end
