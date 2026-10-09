--!strict
-- Host half of the execution log tail: the `logs` block. Runs the effects of
-- lib/monitor/logs/state.luau (SuiteQL through NsHost, timers, links) and
-- feeds results, ticks, keys and clicks back as messages.
--
-- Timer callbacks only check that the pane still exists and start a query
-- (NsHost writes the request file in a process), so they stay cheap. Blocks
-- get no close callback: the next tick finds the pane gone and ends the
-- chain; late query results of a closed block are ignored.

local ConfigHost = require("./config_host")
local NsHost = require("./ns_host")
local Pane = require("./lib/pane")
local State = require("./lib/monitor/logs/state")
local View = require("./lib/monitor/logs/view")

local log = tern.log

type Host = { s: State.State, cx: BlockCx, stopped: boolean, warned: boolean, resized: boolean }

local M = {}

local function warnOnce(h: Host, what: string, err: any)
	if not h.warned then
		h.warned = true
		log.warn("tern-netsuite logs " .. what .. " failed", tostring(err))
	end
end

local exec: (h: Host, effects: { State.Effect }) -> ()

-- Applies `msg`; true when the state changed.
local function dispatch(h: Host, msg: State.Msg): boolean
	local ok, s, effects = pcall(State.update, h.s, msg)
	if not ok then
		warnOnce(h, "update " .. msg.t, s)
		return false
	end
	local changed = s ~= h.s
	h.s = s
	exec(h, effects)
	return changed
end

local function rerender(h: Host)
	if not h.stopped then
		pcall(function()
			h.cx:render()
		end)
	end
end

local function alive(h: Host): boolean
	local ok, panes = pcall(tern.pane.list)
	if not ok then
		return true
	end
	for _, p in panes do
		if p.pane == h.cx.pane then
			return true
		end
	end
	return false
end

local function query(h: Host, e: State.Effect)
	NsHost.query(
		e.connection :: string,
		e.sql :: string,
		e.params,
		{ cx = h.cx, max_rows = e.max_rows },
		function(result: NsHost.Result?, err)
			if h.stopped then
				return
			end
			dispatch(h, {
				t = "result",
				req = e.req,
				rows = if result then result.rows else nil,
				truncated = if result then result.truncated else nil,
				err = err,
				at = os.date("%H:%M:%S"),
			})
			rerender(h)
		end
	)
end

local function arm(h: Host, e: State.Effect)
	tern.timer(e.ms or 0, function()
		if h.stopped then
			return
		end
		if not alive(h) then
			h.stopped = true
			log.debug("tern-netsuite logs pane gone", h.cx.pane)
			return
		end
		if dispatch(h, { t = "tick", req = e.req }) then
			rerender(h)
		end
	end)
end

function exec(h: Host, effects: { State.Effect })
	for _, e in effects do
		if h.stopped then
			return
		end
		if e.t == "query" then
			query(h, e)
		elseif e.t == "timer" then
			arm(h, e)
		elseif e.t == "focus" then
			pcall(function()
				h.cx:frame({ { "focus", e.id or State.FILTER_INPUT } })
			end)
		elseif e.t == "open" then
			-- window.luau routes tern-netsuite://logs/connect to the connect block.
			pcall(function()
				h.cx:open(e.url or "")
			end)
		elseif e.t == "save" then
			pcall(function()
				h.cx:save()
			end)
		elseif e.t == "exit" then
			h.stopped = true
			h.cx:exit(0)
		end
	end
end

local function errorView(err: any): BlockView
	return {
		main = {
			k = "col",
			p = { gap = "sm" },
			c = {
				{
					k = "text",
					p = { spans = { { t = "The NetSuite log view could not render: " .. tostring(err), s = "error" } } },
				},
			},
		} :: any,
	}
end

function M.register()
	tern.block.define(
		"logs",
		{
			init = function(cx: BlockCx, args: { string }, saved: any): Host
				local snap = ConfigHost.load()
				local s, effects =
					State.init(args, saved, snap.config, { decode = tern.json.decode, null = tern.json.null })
				local h: Host = { s = s, cx = cx, stopped = false, warned = false, resized = false }
				exec(h, effects)
				return h
			end,
			view = function(h: Host, cx: BlockCx): BlockView
				-- Only a measured size: Tern 0.7.0 leaves cx at 80x24 (lib/pane.luau).
				local cols, rows = Pane.size(cx.cols, cx.rows, h.resized)
				if rows and (rows ~= h.s.height or cols ~= h.s.width) then
					dispatch(h, { t = "resize", height = rows, width = cols })
				end
				local ok, v = pcall(View.view, h.s)
				if not ok then
					warnOnce(h, "view", v)
					return errorView(v)
				end
				return v :: any
			end,
			title = function(h: Host): string?
				local ok, title = pcall(View.title, h.s)
				return if ok then title else "NetSuite logs"
			end,
			key = function(h: Host, key: Key, cx: BlockCx): boolean?
				h.cx = cx
				return dispatch(h, { t = "key", key = key :: any })
			end,
			resize = function(h: Host, cols: number, rows: number, cx: BlockCx)
				h.cx = cx
				h.resized = true
				dispatch(h, { t = "resize", height = rows, width = cols })
			end,
			event = function(h: Host, ev: UiEvent, cx: BlockCx)
				h.cx = cx
				if ev.ev == "focus" and ev.id == State.FILTER_INPUT then
					dispatch(h, { t = "action", act = "filter-focus" })
				elseif ev.ev == "action" and type(ev.act) == "string" then
					dispatch(h, {
						t = "action",
						act = ev.act,
						value = if type(ev.value) == "string" then ev.value else "",
					})
				end
			end,
			save = function(h: Host): any
				return State.save(h.s)
			end,
		} :: BlockDef<Host>
	)
end

return M
