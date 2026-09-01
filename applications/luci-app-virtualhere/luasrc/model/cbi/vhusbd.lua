--[[
--vhusbd configuration page. Made by 981213
--
]] --
local fs = require "nixio.fs"


m = Map("vhusbd", translate("VirtualHere USB Server"), translatef(
            "<br /> VirtuslHere USB Server用途：<br />可实现通过网络挂载USB设备。<br /><br />使用方法：<br />1.将需要挂载的USB设备插在路由器的USB口并启用服务器。<br />2.客户端主机从<a href='http://www.virtualhere.com/usb_client_software' target='_blank'>官网</a>下载对应的客户端程序运行即可。<br />3.离线注册软件以获得更多的链接授权<br /><br /> 注册格式:<br />xxxxxxxxxxxx,0,MCECDgVxWIWwjupWASYVfVyCAg8Aps8kk/RDEQEdd75G/MU=<br /><br />将xxxxxxxxxxxx替换为你的服务器序列号，然后在客户端程序的注册对话框中注册即可<br /> <br />提示: 12位服务器序列号可以从运行后的VirtuslHere客户端程序中获取.<br />  <br /><br />"))

-- Basic config
m:section(SimpleSection).template = "vhusbd/status"

-- vhusbd
s = m:section(TypedSection, "vhusbd", translate("Settings"))
s.anonymous = true

switch = s:option(Flag, "enabled", translate("Enable"))
switch.rmempty = false

Access = s:option(Flag, "ExtAccess", translate("外网访问(端口:7575)"))
Access.rmempty = false

-- 保存配置后自动重载服务
function m.on_after_commit(self)
    luci.sys.call("/etc/init.d/vhusbd reload >/dev/null 2>&1")
end

return m
