-- Copyright 2014 脕lvaro Fern谩ndez Rojas <noltari@gmail.com>
-- Licensed to the public under the Apache License 2.0.

module("luci.controller.shairport-sync", package.seeall)

function index()
	if not nixio.fs.access("/etc/config/shairport-sync") then
		return
	end

	local page = entry({"admin", "services", "shairport-sync"}, cbi("shairport-sync"), _("AirPlay 2 Receiver"))
	page.dependent = true
	page.acl_depends = { "luci-app-airplay2" }

	entry({"admin", "services", "shairport-sync", "nowplaying"}, call("act_nowplaying")).leaf = true
	entry({"admin", "services", "shairport-sync", "cover"},      call("act_cover")).leaf      = true
	entry({"admin", "services", "shairport-sync", "status"}, call("act_status")).leaf = true
end

function act_status()
	local e = {}
	e.running = luci.sys.call("pgrep shairport-sync >/dev/null") == 0
	luci.http.prepare_content("application/json")
	luci.http.write_json(e)
end

function act_nowplaying()
    local fs = require "nixio.fs"
    luci.http.prepare_content("application/json")
    if fs.access("/tmp/shairport-now.json") then
        luci.http.write(fs.readfile("/tmp/shairport-now.json") or "{}")
    else
        luci.http.write('{"title":"","artist":"","album":"","volume":0,"playing":false,"has_cover":false,"cover_ts":0}')
    end
end

function act_cover()
    local fs = require "nixio.fs"
    if not fs.access("/tmp/shairport-cover.jpg") then
        luci.http.status(404, "Not Found")
        return
    end
    luci.http.header("Cache-Control", "no-store")
    luci.http.prepare_content("image/jpeg")
    luci.http.write(fs.readfile("/tmp/shairport-cover.jpg"))
end
