--[[
--vhusbd configuration page. Made by 981213
--
]] --
local fs = require "nixio.fs"

m = Map("vhusbd", translate("VirtualHere USB Server"), translate(
            "<br /> VirtuslHere USB Server用途：<br />可实现通过网络挂载USB设备。<br /><br />注册方法：<br />1.从<a href='http://www.virtualhere.com/usb_client_software' target='_blank'>官网</a>下载对应平台的客户端程序运行并联机,从对应服务器获取序列号。<br />2.将下面的闪烁部分替换为之前获取到的序列号以获得完整的注册代码<br />3.最后将完整的注册代码输入到客户端的注册入口提交即可:<br /><br />注册代码格式:<br /><span class='blink-red-yellow'>服务器序列号</span>,<span style='color:blue;'>999</span>,<span style='color:blue;'>MCACDkn0jww6R5WOIjFqU/apAg4Um+mDkU2TBcC7fA1FrA==</span><br /><br />" ..
            "<style> " ..
            ".blink-red-yellow { animation: blink-red-yellow 1s step-end infinite; } " ..
            "@keyframes blink-red-yellow { 0%, 100% { color: red; } 50% { color: yellow; } } " ..
            "</style>"
))
-- Basic config
m:section(SimpleSection).template = "vhusbd/status"

-- vhusbd
s = m:section(TypedSection, "vhusbd", translate("Settings"))
s.anonymous = true

switch = s:option(Flag, "enabled", translate("Enable"))
switch.rmempty = false

Access = s:option(Flag, "ExtAccess", translate("外网访问(默认端口:7575)"))
Access.rmempty = false

-- 保存配置后自动重载服务
function m.on_after_commit(self)
    luci.sys.call("/etc/init.d/vhusbd reload >/dev/null 2>&1")
end

-- ===== 在 Settings 区域末尾添加手动重启按钮 =====
local restart_btn = s:option(Button, "restart_btn", translate("重载服务"))
restart_btn.inputstyle = "reload"
function restart_btn.write(self, section)
    luci.sys.call("/etc/init.d/vhusbd restart >/dev/null 2>&1")
end

return m
