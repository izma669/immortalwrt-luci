-- stub lua controller for 19.07 backward compatibility

module("luci.controller.banip", package.seeall)

function index()
	entry({"admin", "control", "banip"}, firstchild(), _("banIP"), 60).acl_depends = { "luci-app-banip" }
	entry({"admin", "control", "banip", "overview"}, view("banip/overview"), _("Overview"), 10)
	entry({"admin", "control", "banip", "ipsetreport"}, view("banip/ipsetreport"), _("IPSet Report"), 20)
	entry({"admin", "control", "banip", "blacklist"}, view("banip/blacklist"), _("Edit Blacklist"), 30)
	entry({"admin", "control", "banip", "whitelist"}, view("banip/whitelist"), _("Edit Whitelist"), 40)
	entry({"admin", "control", "banip", "maclist"}, view("banip/maclist"), _("Edit Maclist"), 50)
	entry({"admin", "control", "banip", "logread"}, view("banip/logread"), _("Log View"), 60)
end
