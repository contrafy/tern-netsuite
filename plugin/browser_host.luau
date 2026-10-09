--!strict
-- Host glue for the account browser block (lib/browser/state.luau): finds
-- and scans the project of the directory it was opened for, runs the
-- SuiteCloud CLI and git processes the core asks for and feeds every answer
-- back as a message. An import is handed to the window (which opens a
-- split) through a single-use tern.kv grant and a
-- `tern-netsuite://browser/import?grant=<id>` link.

local ConfigHost = require("./config_host")
local Link = require("./lib/browser/link")
local Project = require("./lib/sdf/project")
local ProjectHost = require("./project_host")
local Render = require("./lib/browser/render")
local State = require("./lib/browser/state")

local log = tern.log

type Effect = State.Effect
type Msg = State.Msg

type Host = {
	s: State.State,
	cx: BlockCx,
	stopped: boolean,
	warned: boolean,
	scan: ProjectHost.Scan?,
}

local M = {}

local seed = string.format("browser:%d:%.6f:%.17g:%s", os.time(), os.clock(), math.random(), tostring({}))
local counter = 0

local function warnOnce(h: Host, what: string, err: any)
	if not h.warned then
		h.warned = true
		log.warn("tern-netsuite browser " .. what .. " failed", tostring(err))
	end
end

local exec: (h: Host, effects: { Effect }) -> ()

local function dispatch(h: Host, msg: Msg): boolean
	local ok, s, effects = pcall(State.update, h.s, msg)
	if not ok then
		warnOnce(h, "update " .. msg.t, s)
		return false
	end
	local changed = s ~= h.s
	h.s = s
	exec(h, effects)
	return changed or #effects > 0
end

local function deliver(h: Host, msg: Msg)
	if h.stopped then
		return
	end
	dispatch(h, msg)
	-- Synchronous effects deliver during init, before the block is mounted.
	pcall(function()
		h.cx:render()
	end)
end

-- Every browser block on this host shares one SuiteCloud CLI slot: two
-- blocks on projects with the same auth ID would otherwise race on its
-- token refresh (lib/browser/state.luau serializes within a block).
local cliBusy = false
local cliWaiting: { () -> () } = {}

local function cliDone()
	cliBusy = false
	local nextStart = table.remove(cliWaiting, 1)
	if nextStart then
		cliBusy = true
		nextStart()
	end
end

local function run(h: Host, e: Effect)
	local cli = e.step ~= "dirty"
	local function answer(status: number, stdout: string, stderr: string, timedOut: boolean)
		if cli then
			cliDone()
		end
		local msg: any = {
			t = "ran",
			gen = e.gen,
			step = e.step,
			folder = e.folder,
			token = e.token,
			status = status,
			stdout = stdout,
			stderr = stderr,
			timedOut = timedOut,
			now = tern.now(),
		}
		deliver(h, msg)
	end
	local function launch()
		if h.stopped then
			-- The block closed while this run waited for the slot.
			if cli then
				cliDone()
			end
			return
		end
		local ok, err = pcall(function()
			tern.process.run(e.argv :: { string }, { cwd = e.cwd, timeout_ms = e.timeoutMs }, function(r: ProcessResult)
				answer(r.status, r.stdout, r.stderr, r.timed_out)
			end)
		end)
		if not ok then
			answer(-1, "", "could not start " .. tostring((e.argv :: { string })[1]) .. ": " .. tostring(err), false)
		end
	end
	if not cli then
		launch()
	elseif cliBusy then
		table.insert(cliWaiting, launch)
	else
		cliBusy = true
		launch()
	end
end

local function scan(h: Host, e: Effect)
	if h.scan then
		h.scan.cancel()
	end
	local gen = e.gen
	h.scan = ProjectHost.scan(e.root :: string, nil, function(snapshot, err)
		local project = if snapshot then Project.build(snapshot) else nil
		deliver(h, { t = "scanned", gen = gen, project = project, error = err })
	end)
end

local function grantImport(h: Host, e: Effect)
	counter += 1
	local id = Link.newId(seed, counter)
	local ok, err = pcall(function()
		local grant = { request = e.request :: any, label = e.label or "", exp = 0 }
		tern.kv.set(Link.GRANTS_KEY, Link.addGrant(tern.kv.get(Link.GRANTS_KEY), id, grant, os.time()))
		h.cx:open(Link.importUrl(id))
	end)
	if not ok then
		warnOnce(h, "import", err)
		pcall(function()
			h.cx:toast("error", "Tern NetSuite: could not start the import", tostring(err))
		end)
	end
end

function exec(h: Host, effects: { Effect })
	for _, e in effects do
		if h.stopped then
			return
		end
		if e.t == "config" then
			deliver(h, { t = "config", config = ConfigHost.load().config })
		elseif e.t == "find" then
			local gen = e.gen
			ProjectHost.find(e.cwd :: string, function(root: string?)
				deliver(h, { t = "found", gen = gen, root = root })
			end)
		elseif e.t == "scan" then
			scan(h, e)
		elseif e.t == "run" then
			run(h, e)
		elseif e.t == "import" then
			grantImport(h, e)
		elseif e.t == "open" then
			pcall(function()
				h.cx:open(e.path :: string)
			end)
		elseif e.t == "exit" then
			h.stopped = true
			if h.scan then
				h.scan.cancel()
			end
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
					p = { spans = { { t = "NetSuite Browser could not render: " .. tostring(err), s = "error" } } },
				},
			},
		} :: any,
	}
end

function M.register()
	tern.block.define("browser", {
		init = function(cx: BlockCx, args: { string }, saved: any): Host
			local cwd = args[1]
			if cwd == nil and type(saved) == "table" and type(saved.cwd) == "string" then
				cwd = saved.cwd
			end
			local s, effects = State.init({ cwd = cwd or cx.cwd })
			local h: Host = { s = s, cx = cx, stopped = false, warned = false, scan = nil }
			exec(h, effects)
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
			return Render.title(h.s)
		end,
		key = function(h: Host, key: Key, cx: BlockCx): boolean?
			h.cx = cx
			if key.ctrl or key.meta or key.alt then
				return false
			end
			return dispatch(h, { t = "key", name = key.name, text = key.text, shift = key.shift })
		end,
		event = function(h: Host, ev: UiEvent, cx: BlockCx)
			h.cx = cx
			if ev.ev == "focus" and ev.id == "main.search" then
				dispatch(h, { t = "action", act = "search", value = nil })
				return
			end
			if ev.ev ~= "action" or type(ev.act) ~= "string" then
				return
			end
			dispatch(h, { t = "action", act = ev.act, value = if type(ev.value) == "string" then ev.value else nil })
		end,
		save = function(h: Host): any
			return State.saved(h.s)
		end,
	})
end

return M
