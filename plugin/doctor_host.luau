--!strict
-- Host glue for the Doctor block (lib/account/doctor.luau): loads the config,
-- scans the project of the directory it was opened for, runs the processes
-- the core asks for and feeds every answer back as a message.

local ConfigHost = require("./config_host")
local Context = require("./lib/account/context")
local Doctor = require("./lib/account/doctor")

local log = tern.log

type Effect = Doctor.Effect
type Msg = Doctor.Msg

type Host = { s: Doctor.State, cx: BlockCx, stopped: boolean, warned: boolean }

local M = {}

M.MAX_PROJECT_BYTES = 65536
-- Project directories read per scan; a monorepo has tens.
M.MAX_PROJECTS = 200

local lookup: Context.Lookup = {
	exists = function(path: string): boolean
		local ok, present = pcall(tern.fs.exists, path)
		return ok and present == true
	end,
	read = function(path: string): string?
		local ok, text = pcall(tern.fs.read, path, M.MAX_PROJECT_BYTES)
		return if ok then text else nil
	end,
	list = function(path: string): { string }
		return tern.fs.list(path)
	end,
	decode = tern.json.decode,
}

local function warnOnce(h: Host, what: string, err: any)
	if not h.warned then
		h.warned = true
		log.warn("tern-netsuite doctor " .. what .. " failed", tostring(err))
	end
end

local exec: (h: Host, effects: { Effect }) -> ()

local function dispatch(h: Host, msg: Msg): boolean
	local ok, s, effects = pcall(Doctor.update, h.s, msg)
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

local function scan(h: Host, e: Effect)
	local cwd = e.cwd
	local ctx = if cwd then Context.forCwd(cwd, lookup) else nil
	local repo = if cwd then Context.repoRoot(cwd, lookup.exists) else nil
	local projects = if repo
		then Context.projectsUnder(repo, ConfigHost.current().projects.roots, lookup, M.MAX_PROJECTS)
		else {}
	deliver(h, { t = "scanned", gen = e.gen, context = ctx, projects = projects })
end

local function ran(e: Effect, status: number, stdout: string, stderr: string, timedOut: boolean): Msg
	local msg: any = {
		t = "ran",
		gen = e.gen,
		step = e.step,
		authId = e.authId,
		status = status,
		stdout = stdout,
		stderr = stderr,
		timedOut = timedOut,
	}
	return msg
end

local function run(h: Host, e: Effect)
	local ok, err = pcall(function()
		tern.process.run(e.argv, { timeout_ms = e.timeoutMs }, function(r: ProcessResult)
			deliver(h, ran(e, r.status, r.stdout, r.stderr, r.timed_out))
		end)
	end)
	if not ok then
		deliver(h, ran(e, -1, "", "could not start " .. tostring(e.argv[1]) .. ": " .. tostring(err), false))
	end
end

function exec(h: Host, effects: { Effect })
	for _, e in effects do
		if h.stopped then
			return
		end
		if e.t == "config" then
			local snap = ConfigHost.load()
			deliver(h, {
				t = "config",
				gen = e.gen,
				config = snap.config,
				diagnostics = snap.diagnostics,
				path = snap.path,
				status = snap.status :: string,
			})
		elseif e.t == "scan" then
			scan(h, e)
		elseif e.t == "run" then
			run(h, e)
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
					p = { spans = { { t = "NetSuite Doctor could not render: " .. tostring(err), s = "error" } } },
				},
			},
		} :: any,
	}
end

function M.register()
	tern.block.define("doctor", {
		init = function(cx: BlockCx, args: { string }, _saved: any): Host
			local cwd = args[1] or cx.cwd
			local s, effects = Doctor.init({ cwd = cwd })
			local h: Host = { s = s, cx = cx, stopped = false, warned = false }
			exec(h, effects)
			return h
		end,
		view = function(h: Host, _cx: BlockCx): BlockView
			local ok, v = pcall(Doctor.view, h.s)
			if not ok then
				warnOnce(h, "view", v)
				return errorView(v)
			end
			return v :: any
		end,
		title = function(h: Host): string?
			return Doctor.title(h.s)
		end,
		key = function(h: Host, key: Key, cx: BlockCx): boolean?
			h.cx = cx
			return dispatch(h, { t = "key", name = key.name })
		end,
	})
end

return M
