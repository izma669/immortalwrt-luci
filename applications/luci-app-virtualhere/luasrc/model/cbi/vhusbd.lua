--[[
--vhusbd configuration page. Made by 981213
--
]] --
local fs = require "nixio.fs"


m = Map("vhusbd", translate("VirtualHere USB Server"), translatef(
            "<br /> VirtuslHere USB Server用途：<br />可实现通过网络挂载USB设备。<br /><br />使用方法：<br />1.将需要挂载的USB设备插在路由器的USB口并启用服务器。<br />2.客户端主机从<a href='http://www.virtualhere.com/usb_client_software' target='_blank'>官网</a>下载对应的客户端程序运行即可。<br /><br />注册方法：<br />以WINDOWS为例, 从运行后的VirtuslHere Client 程序中获取设备的12位许可码.<br /> 输入许可代码注册，格式：xxxxxxxxxxxx,999,MCACDkn0jww6R5WOIjFqU/apAg4Um+mDkU2TBcC7fA1FrA==<br /> <br />注意: 如不注册就只能连接一个设备<br /><br />"))

-- Basic config
m:section(SimpleSection).template = "vhusbd/status"

-- vhusbd
s = m:section(TypedSection, "vhusbd", translate("Settings"))
s.anonymous = true

switch = s:option(Flag, "enabled", translate("Enable"))
switch.rmempty = false

Access = s:option(Flag, "ExtAccess", translate("外网访问"))
Access.rmempty = false

-- 保存配置后自动重载服务
function m.on_after_commit(self)
    luci.sys.call("/etc/init.d/vhusbd reload >/dev/null 2>&1")
end

return m
