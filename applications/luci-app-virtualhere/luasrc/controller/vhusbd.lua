module("luci.controller.vhusbd", package.seeall)

function index()
    entry({"admin", "services", "vhusbd"}, template("vhusbd/status"), _("VirtualHere"), 60)
    entry({"admin", "services", "vhusbd", "action"}, call("action_dispatch")).leaf = true
end

function action_dispatch()
    local action = luci.http.formvalue("action")
    local out = "ERROR:未知操作"

    if action == "status" then
        -- 用 ps 排除僵尸进程 Z，比 pidof 更准确
        local s = luci.sys.exec("ps | grep '[v]husbd' | grep -v 'Z' | wc -l"):gsub("%s+", "")
        out = (tonumber(s) > 0) and "RUNNING" or "STOPPED"

    elseif action == "start" then
        luci.sys.exec("/etc/init.d/vhusbd start >/dev/null 2>&1")
        out = "SUCCESS:服务已启动"
    elseif action == "stop" then
        luci.sys.exec("/etc/init.d/vhusbd stop >/dev/null 2>&1")
        luci.sys.exec("killall -9 vhusbd >/dev/null 2>&1") -- 强制清理残留进程
        out = "SUCCESS:服务已停止"
    elseif action == "restart" then
        luci.sys.exec("/etc/init.d/vhusbd restart >/dev/null 2>&1")
        out = "SUCCESS:服务已重启"

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

    elseif action == "logs" then
        out = luci.sys.exec("logread | grep -i vhusbd | tail -n 50")
        if out == "" then out = "暂无日志信息" end
    end

    luci.http.prepare_content("text/plain")
    luci.http.write(out)
end
