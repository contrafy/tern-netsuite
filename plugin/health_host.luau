--!strict
-- Host glue for the `health` block. NetSuite is never queried here: the
-- window's poller (health_window.luau) stores one summary per connection
-- in tern.kv, and this block re-reads them on a timer. `r` asks the window
-- to poll now through a tern-netsuite://health/refresh link.

local ConfigHost = require("./config_host")
local Model = require("./lib/monitor/health/model")
local View = require("./lib/monitor/health/view")

local log = tern.log

local M = {}

M.TICK_MS = 2000
M.REFRESH_LINK = "tern-netsuite://health/refresh"

type Host = {
	cx: BlockCx,
	connections: { { id: string, label: string } },
	entries: { View.Entry },
	sig: string,
	stopped: boolean,
	warned: boolean,
}

local function warnOnce(h: Host, what: string, err: any)
	if not h.warned then
		h.warned = true
		log.warn("tern-netsuite health " .. what .. " failed", tostring(err))
	end
end

local function summaryKey(id: string): string
	return "health.summary." .. id
end

local function loadConnections(h: Host)
	local cfg = ConfigHost.load().config
	h.connections = {}
	for _, c in Model.conns(cfg) do
		table.insert(h.connections, { id = c.id, label = c.label })
	end
end

-- Re-reads the summaries; true when anything shown changed. Ages are shown
-- to the minute, so the minute is part of the signature.
local function read(h: Host): boolean
	local entries: { View.Entry } = {}
	local parts: { string } = { tostring(os.time() // 60) }
	for _, c in h.connections do
		local ok, v = pcall(tern.kv.get, summaryKey(c.id))
		local s = if ok then Model.decode(v) else nil
		table.insert(entries, { id = c.id, label = c.label, summary = s })
		table.insert(parts, c.id .. ":" .. (if s then tostring(s.at) .. s.state else "-"))
	end
	h.entries = entries
	local sig = table.concat(parts, "|")
	local changed = sig ~= h.sig
	h.sig = sig
	return changed
end

-- Blocks get no close callback: the timer stops once the pane is gone.
local function watch(h: Host)
	local function tick()
		if h.stopped then
			return
		end
		local alive = false
		for _, p in tern.pane.list() do
			if p.pane == h.cx.pane then
				alive = true
				break
			end
		end
		if not alive then
			h.stopped = true
			return
		end
		local ok, changed = pcall(read, h)
		if not ok then
			warnOnce(h, "read", changed)
		elseif changed then
			pcall(function()
				h.cx:render()
			end)
		end
		tern.timer(M.TICK_MS, tick)
	end
	tern.timer(M.TICK_MS, tick)
end

local function errorView(err: any): BlockView
	return {
		main = {
			k = "col",
			p = { gap = "sm" },
			c = {
				{
					k = "text",
					p = { spans = { { t = "NetSuite health could not render: " .. tostring(err), s = "error" } } },
				},
			},
		} :: any,
	}
end

function M.register()
	tern.block.define("health", {
		init = function(cx: BlockCx, _args: { string }, _saved: any): Host
			local h: Host = { cx = cx, connections = {}, entries = {}, sig = "", stopped = false, warned = false }
			local ok, err = pcall(function()
				loadConnections(h)
				read(h)
			end)
			if not ok then
				warnOnce(h, "init", err)
			end
			watch(h)
			return h
		end,
		view = function(h: Host, _cx: BlockCx): BlockView
			local ok, v = pcall(View.render, { entries = h.entries, now = os.time() })
			if not ok then
				warnOnce(h, "view", v)
				return errorView(v)
			end
			return v :: any
		end,
		title = function(h: Host): string?
			return View.title(h.entries)
		end,
		key = function(h: Host, key: Key, cx: BlockCx): boolean?
			h.cx = cx
			if key.name == "escape" then
				h.stopped = true
				cx:exit(0)
				return false
			elseif key.name == "r" then
				pcall(loadConnections, h)
				pcall(read, h)
				cx:open(M.REFRESH_LINK)
				return true
			end
			return false
		end,
	})
end

return M
