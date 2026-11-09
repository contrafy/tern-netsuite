--!strict
-- Host glue for the drift block (lib/drift/state.luau): finds and scans the
-- project, creates the scratch project the account's copies are imported
-- into (under <plugin data>/drift/work, never the user's project), runs the
-- SuiteCloud CLI commands the core asks for in their auth ID's machine-wide
-- CLI slot (cli_slot_host.luau), reads the files they wrote and keeps the
-- last result per project and auth ID under <plugin data>/drift/cache.

local CliSlotHost = require("./cli_slot_host")
local ConfigHost = require("./config_host")
local Cache = require("./lib/drift/cache")
local Link = require("./lib/drift/link")
local Project = require("./lib/sdf/project")
local ProjectHost = require("./project_host")
local Render = require("./lib/drift/render")
local Scratch = require("./lib/drift/scratch")
local State = require("./lib/drift/state")

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

-- Scratch directories older than this (minutes) are left over from closed
-- blocks or reloads and removed when a run starts.
M.STALE_MINUTES = 120

local seed = string.format("%d-%d", os.time(), math.random(1, 2 ^ 30))
local counter = 0

local function workDir(): string
	return tern.plugin.data .. "/" .. Scratch.DIR
end

local function cacheDir(): string
	return tern.plugin.data .. "/" .. Cache.DIR
end

local function warnOnce(h: Host, what: string, err: any)
	if not h.warned then
		h.warned = true
		log.warn("tern-netsuite drift " .. what .. " failed", tostring(err))
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
	pcall(function()
		h.cx:render()
	end)
end

-- Only directories this adapter creates are ever removed.
local function removeScratch(dir: string?)
	local base = workDir() .. "/"
	if dir and string.sub(dir, 1, #base) == base and not string.find(string.sub(dir, #base + 1), "/", 1, true) then
		pcall(tern.fs.remove, dir)
	end
end

local function sweep()
	pcall(function()
		tern.process.run({
			"find",
			workDir(),
			"-mindepth",
			"1",
			"-maxdepth",
			"1",
			"-name",
			"run-*",
			"-mmin",
			"+" .. M.STALE_MINUTES,
			"-exec",
			"rm",
			"-rf",
			"{}",
			"+",
		}, { timeout_ms = 30000 }, function() end)
	end)
end

local function prepare(h: Host, e: Effect)
	counter += 1
	local dir = string.format("%s/run-%s-%d", workDir(), seed, counter)
	local plan = e.plan :: any
	local ok, err = pcall(function()
		tern.fs.mkdir(dir)
		for _, d in plan.dirs do
			tern.fs.mkdir(dir .. "/" .. d)
		end
		for _, w in plan.writes do
			tern.fs.write(dir .. "/" .. w.path, w.text)
		end
	end)
	if not ok then
		removeScratch(dir)
	end
	sweep()
	deliver(h, {
		t = "prepared",
		gen = e.gen,
		run = e.run :: number,
		dir = if ok then dir else nil,
		error = if ok then nil else tostring(err),
	})
end

local function readAll(paths: { string }?): { [string]: string }
	local out: { [string]: string } = {}
	local list: { string } = paths or {}
	for _, p in list do
		local ok, text = pcall(tern.fs.read, p, State.READ_BYTES)
		if ok and type(text) == "string" then
			out[p] = text
		end
	end
	return out
end

local function run(h: Host, e: Effect)
	local argv = e.argv :: { string }
	local timeout = e.timeoutMs :: number
	local wrapped = if e.slot then CliSlotHost.wrap(argv, e.slot, timeout) else argv
	local function answer(status: number, stdout: string, stderr: string, timedOut: boolean)
		if h.stopped then
			-- The block is gone; nothing else writes into its scratch project.
			removeScratch(e.dir)
			return
		end
		local msg: any = {
			t = "ran",
			gen = e.gen,
			run = e.run,
			dir = e.dir,
			step = e.step,
			argv = argv,
			status = status,
			stdout = stdout,
			stderr = stderr,
			timedOut = timedOut,
			texts = readAll(e.reads),
			now = tern.now(),
			clock = os.time(),
		}
		deliver(h, msg)
	end
	local ok, err = pcall(function()
		tern.process.run(wrapped, { cwd = e.cwd, timeout_ms = timeout }, function(r: ProcessResult)
			answer(r.status, r.stdout, r.stderr, r.timed_out)
		end)
	end)
	if not ok then
		answer(-1, "", "could not start " .. tostring(argv[1]) .. ": " .. tostring(err), false)
	end
end

local function scan(h: Host, e: Effect)
	if h.scan then
		h.scan.cancel()
	end
	local gen = e.gen
	h.scan = ProjectHost.scan(e.root :: string, nil, function(snapshot, err)
		local project = if snapshot then Project.build(snapshot) else nil
		local texts: { [string]: string } = {}
		if snapshot then
			for _, f in snapshot.files do
				if f.text then
					texts[f.path] = f.text
				end
			end
		end
		local realRoot = if snapshot then Cache.resolvedRoot(snapshot.root, snapshot.files) else nil
		deliver(h, { t = "scanned", gen = gen, project = project, texts = texts, realRoot = realRoot, error = err })
	end)
end

local function load(h: Host, e: Effect)
	local file = e.file :: string
	local ok, value = pcall(function()
		local path = cacheDir() .. "/" .. file
		if not tern.fs.exists(path) then
			return nil
		end
		return tern.json.decode(tern.fs.read(path))
	end)
	if not ok then
		warnOnce(h, "cache read", value)
	end
	deliver(h, { t = "loaded", gen = e.gen, file = file, value = if ok then value else nil })
end

local function save(h: Host, e: Effect)
	local ok, err = pcall(function()
		tern.fs.mkdir(cacheDir())
		tern.fs.write(cacheDir() .. "/" .. (e.file :: string), tern.json.encode(e.value))
	end)
	if not ok then
		warnOnce(h, "cache write", err)
	end
end

function exec(h: Host, effects: { Effect })
	for _, e in effects do
		if h.stopped then
			return
		end
		if e.t == "config" then
			deliver(h, { t = "config", config = ConfigHost.load().config, now = tern.now(), clock = os.time() })
		elseif e.t == "find" then
			local gen = e.gen
			ProjectHost.find(e.cwd :: string, function(root: string?)
				deliver(h, { t = "found", gen = gen, root = root })
			end)
		elseif e.t == "scan" then
			scan(h, e)
		elseif e.t == "load" then
			load(h, e)
		elseif e.t == "save" then
			save(h, e)
		elseif e.t == "prepare" then
			prepare(h, e)
		elseif e.t == "run" then
			run(h, e)
		elseif e.t == "cleanup" then
			removeScratch(e.dir)
		elseif e.t == "open" then
			pcall(function()
				h.cx:open(e.path :: string)
			end)
		elseif e.t == "exit" then
			h.stopped = true
			if h.scan then
				h.scan.cancel()
			end
			removeScratch(State.idleDir(h.s))
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
					p = { spans = { { t = "NetSuite Drift could not render: " .. tostring(err), s = "error" } } },
				},
			},
		} :: any,
	}
end

function M.register()
	tern.block.define("drift", {
		init = function(cx: BlockCx, args: { string }, saved: any): Host
			local cwd, held = Link.fromArgs(args)
			local authId: string? = nil
			local accountOnly = false
			local heldFor: string? = nil
			if type(saved) == "table" then
				if cwd == nil and type(saved.cwd) == "string" then
					cwd = saved.cwd
				end
				if type(saved.held) == "boolean" then
					held = saved.held
				end
				if type(saved.authId) == "string" and Scratch.unsafeAuthId(saved.authId) == nil then
					authId = saved.authId
				end
				accountOnly = saved.accountOnly == true
				heldFor = if type(saved.heldFor) == "string" then saved.heldFor else nil
			end
			local s, effects = State.init({
				cwd = cwd or cx.cwd,
				held = held,
				heldFor = heldFor,
				authId = authId,
				accountOnly = accountOnly,
			})
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
