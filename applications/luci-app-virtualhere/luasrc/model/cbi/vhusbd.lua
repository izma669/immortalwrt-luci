--[[
--vhusbd configuration page. Made by 981213
--
]] --
local fs = require "nixio.fs"

m = Map("vhusbd", translate("VirtualHere USB Server"), translate(
            "<br /> VirtuslHere USB Server用途：<br />可实现通过网络挂载USB设备。<br /><br />使用方法：<br />1.将需要挂载的USB设备插在路由器的USB口并启用服务器。<br />2.客户端主机从<a href='http://www.virtualhere.com/usb_client_software' target='_blank'>官网</a>下载对应的客户端程序运行即可。<br />3.离线注册软件以获得更多的链接授权<br /><br /> 注册格式:<br /><span class='blink-red-yellow'>xxxxxxxxxxxx</span>,<span class='blink-blue-yellow'>999</span>,<span class='blink-green-yellow'>MCACDkn0jww6R5WOIjFqU/apAg4Um+mDkU2TBcC7fA1FrA==</span><br /><br />红色字部分是你的服务器序列号,蓝色是你想解锁授权的数量,绿色是key<br /><br />注册方式：<br /><br />启动客户端连接到服务器后将获取到的12位序列号替换上面的注册代码中红色部分完成注册即可  <br /><br />" ..
            "<style> " ..
            ".blink-red-yellow { animation: blink-red-yellow 1s step-end infinite; } " ..
            "@keyframes blink-red-yellow { 0%, 100% { color: red; } 50% { color: yellow; } } " ..
            ".blink-blue-yellow { animation: blink-blue-yellow 1s step-end infinite; } " ..
            "@keyframes blink-blue-yellow { 0%, 100% { color: blue; } 50% { color: yellow; } } " ..
            ".blink-green-yellow { animation: blink-green-yellow 1s step-end infinite; } " ..
            "@keyframes blink-green-yellow { 0%, 100% { color: green; } 50% { color: yellow; } } " ..
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

return m
