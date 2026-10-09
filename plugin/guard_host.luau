--!strict
-- Host glue for the production deploy guard: the approve block
-- (`tern-netsuite.approve`, answering shell/tern-netsuite-guard requests) and
-- the `spawn` hook that gives new panes the guard's environment. Runs the
-- effects of lib/guard/session.luau and feeds results, keys, events and
-- liveness ticks back as messages; all decisions live in the session.

local ConfigHost = require("./config_host")
local Env = require("./lib/guard/env")
local Protocol = require("./lib/guard/protocol")
local Render = require("./lib/guard/render")
local Session = require("./lib/guard/session")

local log = tern.log

type Effect = Session.Effect
type Msg = Session.Msg

type Host = { s: Session.State, cx: BlockCx, stopped: boolean, warned: boolean }

local M = {}

M.LIVENESS_MS = 1000
M.SPOOL = tern.plugin.data .. "/spool"
M.AUDIT_LOG = tern.plugin.data .. "/audit.log"

local function warnOnce(h: Host, what: string, err: any)
	if not h.warned then
		h.warned = true
		log.warn("tern-netsuite approve " .. what .. " failed", tostring(err))
	end
end

local function paneIds(): { string }
	local out: { string } = {}
	for _, p in tern.pane.list() do
		table.insert(out, tostring(p.pane))
	end
	return out
end

local exec: (h: Host, effects: { Effect }) -> ()

local function dispatch(h: Host, msg: Msg): boolean
	if msg.now == nil then
		msg.now = os.time()
	end
	local ok, s, effects, changed = pcall(Session.update, h.s, msg)
	if not ok then
		warnOnce(h, "update " .. msg.t, s)
		return false
	end
	h.s = s
	exec(h, effects)
	return changed
end

local function deliver(h: Host, e: Effect, result: Session.ProcessResult)
	if h.stopped then
		return
	end
	dispatch(h, { t = "result", tag = e.tag, gen = e.gen, result = result })
	if not h.stopped then
		h.cx:render()
	end
end

local function run(h: Host, e: Effect)
	local opts: ProcessOptions = { timeout_ms = e.timeout_ms or 5000, stdin = e.stdin }
	local ok, err = pcall(function()
		tern.process.run(e.argv :: { string }, opts, function(res: ProcessResult)
			deliver(h, e, res)
		end)
	end)
	if not ok then
		-- Delivered on the next tick: effects never re-enter update.
		tern.timer(1, function()
			deliver(h, e, { status = -1, stdout = "", stderr = tostring(err), timed_out = false })
		end)
	end
end

local function write(h: Host, e: Effect)
	local ok, err = pcall(function()
		tern.fs.write(e.path :: string, e.text :: string)
	end)
	if not ok then
		tern.timer(1, function()
			deliver(h, e, { status = -1, stdout = "", stderr = tostring(err), timed_out = false })
		end)
		return
	end
	run(h, e)
end

-- One JSON line appended with O_APPEND (tern.fs.write replaces files).
local function appendAudit(line: string)
	local ok, err = pcall(function()
		tern.process.run(
			{ "/bin/sh", "-c", 'umask 077; cat >>"$1"', "tern-netsuite-audit", M.AUDIT_LOG },
			{ stdin = line, timeout_ms = 5000 },
			function(res: ProcessResult)
				if res.status ~= 0 then
					log.warn("tern-netsuite audit append failed", res.stderr)
				end
			end
		)
	end)
	if not ok then
		log.warn("tern-netsuite audit append failed", tostring(err))
	end
end

function exec(h: Host, effects: { Effect })
	for _, e in effects do
		if h.stopped then
			return
		end
		local t = e.t
		if t == "run" then
			run(h, e)
		elseif t == "write" then
			write(h, e)
		elseif t == "remove" then
			pcall(tern.fs.remove, e.path :: string)
		elseif t == "audit" then
			appendAudit(e.line :: string)
		elseif t == "focus" then
			-- The input appears in the view this effect comes with: render
			-- it first, focus on the next tick.
			local id = e.id or Session.TYPED_INPUT
			h.cx:render()
			tern.timer(1, function()
				if not h.stopped then
					h.cx:frame({ { "focus", id } })
				end
			end)
		elseif t == "exit" then
			h.stopped = true
			-- `tern open --wait` ignores the exit code, and a non-zero exit
			-- leaves a sheet that blocks the wait: always 0.
			h.cx:exit(0)
		end
	end
end

-- Blocks get no close callback: poll the pane list. The same tick reports
-- the requesting pane and the guard's cancel marker to the session.
local function watch(h: Host)
	local function tick()
		if h.stopped then
			return
		end
		local panes = paneIds()
		if table.find(panes, tostring(h.cx.pane)) == nil then
			h.stopped = true
			return
		end
		local w = Session.watch(h.s)
		local msg: Msg = { t = "tick" }
		if w.pane then
			msg.paneAlive = table.find(panes, w.pane) ~= nil
		end
		if w.cancelPath then
			local ok, present = pcall(tern.fs.exists, w.cancelPath :: string)
			msg.cancelled = ok and present == true
		end
		if dispatch(h, msg) and not h.stopped then
			h.cx:render()
		end
		if not h.stopped then
			tern.timer(M.LIVENESS_MS, tick)
		end
	end
	tern.timer(M.LIVENESS_MS, tick)
end

local function errorView(err: any): BlockView
	return {
		main = {
			k = "col",
			p = { gap = "sm" },
			c = {
				{
					k = "text",
					p = { spans = { { t = "Tern NetSuite approve could not render: " .. tostring(err), s = "error" } } },
				},
			},
		} :: any,
	}
end

local function requestFile(arg: string?): { text: string?, error: string? }?
	if arg == nil then
		return nil
	end
	local ok, text = pcall(tern.fs.read, arg, Protocol.MAX_REQUEST_BYTES)
	if ok then
		return { text = text }
	end
	return { error = tostring(text) }
end

function M.register()
	pcall(tern.fs.mkdir, M.SPOOL)

	tern.on("spawn", function(spec: SpawnSpec): SpawnSpec?
		for k, v in Env.forSpawn(ConfigHost.current(), M.SPOOL) do
			spec.env[k] = v
		end
		return spec
	end)

	tern.block.define("approve", {
		init = function(cx: BlockCx, args: { string }, _saved: any): Host
			local s, effects = Session.init({
				args = args,
				now = os.time(),
				spool = M.SPOOL,
				request = requestFile(args[1]),
				panes = paneIds(),
				decode = tern.json.decode,
				config = ConfigHost.load().config,
			})
			local h: Host = { s = s, cx = cx, stopped = false, warned = false }
			log.info("tern-netsuite approve.init", s.phase, args[1] or "")
			exec(h, effects)
			watch(h)
			return h
		end,
		view = function(h: Host, _cx: BlockCx): BlockView
			local ok, v = pcall(Render.view, h.s)
			if not ok then
				warnOnce(h, "view", v)
				return errorView(v)
			end
			return v :: any
		end,
		title = function(h: Host): string?
			local ok, title = pcall(Render.title, h.s)
			return if ok then title else "NetSuite approve"
		end,
		key = function(h: Host, key: Key, cx: BlockCx): boolean?
			h.cx = cx
			return dispatch(h, { t = "key", key = key :: any })
		end,
		event = function(h: Host, ev: UiEvent, cx: BlockCx)
			h.cx = cx
			if ev.ev == "action" and type(ev.act) == "string" then
				dispatch(h, { t = "action", act = ev.act })
			end
		end,
	})
end

return M
