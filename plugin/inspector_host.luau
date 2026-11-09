--!strict
-- Host half of the record inspector: the `inspect` block. Runs the effects
-- of lib/inspector/state.luau (SuiteQL through NsHost, opening the record's
-- NetSuite page, focus, save, exit) and feeds results, keys and clicks back
-- as messages. Late results of a closed block are ignored.

local ConfigHost = require("./config_host")
local NsHost = require("./ns_host")
local Pane = require("./lib/pane")
local State = require("./lib/inspector/state")
local View = require("./lib/inspector/view")

local log = tern.log

type Host = { s: State.State, cx: BlockCx, stopped: boolean, warned: boolean, resized: boolean }

local M = {}

local function warnOnce(h: Host, what: string, err: any)
	if not h.warned then
		h.warned = true
		log.warn("tern-netsuite inspect " .. what .. " failed", tostring(err))
	end
end

local exec: (h: Host, effects: { State.Effect }) -> ()

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
			dispatch(h, { t = "result", req = e.req, rows = if result then result.rows else nil, err = err })
			rerender(h)
		end
	)
end

function exec(h: Host, effects: { State.Effect })
	for _, e in effects do
		if h.stopped then
			return
		end
		if e.t == "query" then
			query(h, e)
		elseif e.t == "browse" then
			-- An https URL: window.luau's route.link leaves it to the OS browser.
			pcall(function()
				h.cx:open(e.url or "")
			end)
		elseif e.t == "focus" then
			pcall(function()
				h.cx:frame({ { "focus", e.id or State.INPUT } })
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
					p = { spans = { { t = "The record inspector could not render: " .. tostring(err), s = "error" } } },
				},
			},
		} :: any,
	}
end

function M.register()
	tern.block.define(
		"inspect",
		{
			init = function(cx: BlockCx, args: { string }, saved: any): Host
				local snap = ConfigHost.load()
				local s, effects = State.init(args, saved, snap.config, { null = tern.json.null })
				local h: Host = { s = s, cx = cx, stopped = false, warned = false, resized = false }
				exec(h, effects)
				return h
			end,
			view = function(h: Host, cx: BlockCx): BlockView
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
				return if ok then title else "NetSuite record"
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
				if ev.ev == "focus" and ev.id == State.INPUT then
					dispatch(h, { t = "action", act = "input-focus" })
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
