module("luci.controller.nginx-manager", package.seeall)

function index()
    if not nixio.fs.access("/etc/config/nginx") then
        return
    end
    -- 只保留主页路由，所有具体逻辑全部在 overview.htm 内部处理
    entry({"admin", "services", "nginx-manager"}, template("nginx-manager/overview"), _("Nginx 管理器"), 30).leaf = true
end
