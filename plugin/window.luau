--!strict
-- Window half: link routing, palette commands and chrome. Every feature lives
-- in a `*_window.luau` adapter exporting `register()` and, when it owns links,
-- `route(link, cx)` for its area (`tern-netsuite://<area>/...`).

local BrowserWindow = require("./browser_window")
local ConfigHost = require("./config_host")
local ExplorerWindow = require("./explorer_window")
local GuardWindow = require("./guard_window")
local HealthWindow = require("./health_window")
local HistoryWindow = require("./history_window")
local LogsWindow = require("./logs_window")
local NsWindow = require("./ns_window")
local ScaffoldWindow = require("./scaffold_window")
local StatusWindow = require("./status_window")

local log = tern.log

local SCHEME = "tern-netsuite://"

type Route = (link: LinkRequest, cx: WindowCx) -> RouteDecision?

local routes: { [string]: Route } = {
	ns = NsWindow.route,
	health = HealthWindow.route,
	logs = LogsWindow.route,
	explorer = ExplorerWindow.route,
	history = HistoryWindow.route,
	browser = BrowserWindow.route,
}

-- Every tern-netsuite:// URL must be claimed here: an unclaimed one, or a
-- handler error, falls through to the OS, which shows a "no application"
-- dialog on macOS.
tern.route.link(function(link: LinkRequest, cx: WindowCx): RouteDecision?
	if string.sub(link.url, 1, #SCHEME) ~= SCHEME then
		return nil
	end
	local decision: RouteDecision? = nil
	local ok, err = pcall(function()
		local area = string.match(link.url, "^tern%-netsuite://([%w%-]+)")
		local route = if area then routes[area] else nil
		if route then
			decision = route(link, cx)
		else
			cx:toast("error", "Tern NetSuite: unknown link", link.url)
		end
	end)
	if not ok then
		log.warn("tern-netsuite route.link failed", link.url, tostring(err))
		pcall(function()
			cx:toast("error", "Tern NetSuite: link failed", tostring(err))
		end)
	end
	return decision or { handled = true }
end)

tern.command({
	id = "config",
	title = "Tern NetSuite: Open config",
	icon = "sliders",
	run = function(cx: WindowCx)
		local snap = ConfigHost.load()
		if snap.path == nil then
			cx:toast("error", "Tern NetSuite: no config path", "Neither XDG_CONFIG_HOME nor HOME is set")
			return
		end
		if snap.status == "missing" then
			cx:copy(snap.path)
			cx:toast(
				"info",
				"Tern NetSuite: no config file yet",
				snap.path .. " (path copied; examples/config.json shows every key)"
			)
			return
		end
		cx:open(snap.path)
	end,
})

-- Config edits reach chrome formatters (which may not do I/O) through a
-- throttled re-read on focus changes and finished commands.
local CONFIG_RECHECK_MS = 2000
local lastConfigCheck = tern.now()

local function recheckConfig()
	local now = tern.now()
	if now - lastConfigCheck < CONFIG_RECHECK_MS then
		return
	end
	lastConfigCheck = now
	local ok, err = pcall(ConfigHost.load)
	if not ok then
		log.warn("tern-netsuite config reload failed", tostring(err))
	end
end

ConfigHost.onChange(function()
	pcall(tern.chrome.refresh)
end)
tern.on("focus", recheckConfig)
tern.on("command_finished", recheckConfig)

StatusWindow.register()
NsWindow.register()
GuardWindow.register()
ScaffoldWindow.register()
HealthWindow.register()
LogsWindow.register()
ExplorerWindow.register()
HistoryWindow.register()
StatusWindow.addProvider(HistoryWindow.ciSegment)
BrowserWindow.register()
