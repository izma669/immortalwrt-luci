module("luci.controller.gmediarender", package.seeall)

function index()
    if not nixio.fs.access("/etc/config/gmediarender") then
        return
    end

    entry({"admin", "services", "gmediarender"},
        cbi("gmediarender"),
        _("GMediaRender"), 60).dependent = true

    entry({"admin", "services", "gmediarender", "status"},
        call("action_status")).leaf = true
end

function action_status()
    local sys = require "luci.sys"
    local uci = require "luci.model.uci".cursor()

    local running = sys.call("pgrep -f gmediarender >/dev/null") == 0
    local enabled = uci:get("gmediarender", "main", "enabled")

    luci.http.prepare_content("application/json")
    luci.http.write_json({
        running = running,
        enabled = enabled == "1"
    })
end
