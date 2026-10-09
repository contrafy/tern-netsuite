--!strict
-- Host glue for deploy history. Records every `project:deploy` and
-- `file:upload` command line that finishes in a Tern pane (the host
-- `command_finished` hook: lens callbacks are replayed when Tern rehydrates
-- a pane and would record twice) to `<plugin data>/history.jsonl`, and
-- defines the `history` block (lib/history/state.luau + view.luau).
--
-- A record waits for its git state and account (auth id lookups run at
-- command start, so they are usually cached by the end) and is written
-- after DEADLINE_MS with whatever has arrived.

local ConfigHost = require("./config_host")
local Context = require("./lib/account/context")
local Git = require("./lib/history/git")
local Link = require("./lib/history/link")
local Manageauth = require("./lib/account/manageauth")
local Recognize = require("./lib/history/recognize")
local Record = require("./lib/history/record")
local Resolve = require("./lib/account/resolve")
local Settings = require("./lib/history/settings")
local State = require("./lib/history/state")
local Store = require("./lib/history/store")
local View = require("./lib/history/view")

local log = tern.log

local M = {}

M.PATH = tern.plugin.data .. "/history.jsonl"
M.AUDIT_LOG = tern.plugin.data .. "/audit.log"
M.DEADLINE_MS = 15000
M.GIT_TIMEOUT_MS = 5000
M.INFO_TIMEOUT_MS = 60000
M.WRITE_TIMEOUT_MS = 5000
M.MAX_PROJECT_BYTES = 65536
-- Far above MAX entries x MAX_LINE; a larger file is left alone.
M.MAX_FILE_BYTES = 16777216

local lookup: Context.Lookup = {
	exists = function(path: string): boolean
		local ok, present = pcall(tern.fs.exists, path)
		return ok and present == true
	end,
	read = function(path: string): string?
		local ok, text = pcall(tern.fs.read, path, M.MAX_PROJECT_BYTES)
		return if ok then text else nil
	end,
	decode = tern.json.decode,
}

local function run(argv: { string }, opts: ProcessOptions, done: (ProcessResult) -> ())
	local ok, err = pcall(function()
		tern.process.run(argv, opts, done)
	end)
	if not ok then
		-- Delivered on the next tick so callers never re-enter themselves.
		tern.timer(1, function()
			done({ status = -1, stdout = "", stderr = tostring(err), timed_out = false })
		end)
	end
end

-- Auth id -> account ------------------------------------------------------

local cache: Resolve.Cache = {}
local waiting: { [string]: { () -> () } } = {}

local function resolveOpts(): Resolve.Options
	return { config = ConfigHost.current(), cache = cache, now = tern.now() }
end

-- Runs `manageauth --info` unless the answer is configured or cached;
-- `done` runs once the cache holds the answer (at once when no lookup runs).
local function lookupAuth(authId: string, done: (() -> ())?)
	local queue = waiting[authId]
	if queue then
		if done then
			table.insert(queue, done)
		end
		return
	end
	if not Resolve.needsLookup(authId, resolveOpts()) then
		if done then
			done()
		end
		return
	end
	local q: { () -> () } = if done then { done } else {}
	waiting[authId] = q
	local program = ConfigHost.current().suitecloud.program
	run({ program, "account:manageauth", "--info", authId }, {
		timeout_ms = M.INFO_TIMEOUT_MS,
		stdin = "",
	}, function(r: ProcessResult)
		local info = if r.status == 0 then Manageauth.parseInfo(Manageauth.lines(r.stdout)) else nil
		if info and info.accountId then
			cache = Resolve.store(cache, Resolve.fromInfo(info, tern.now()))
		else
			local why = if r.timed_out
				then "timed out"
				else Manageauth.errorText(Manageauth.lines(r.stderr .. "\n" .. r.stdout))
			cache = Resolve.store(cache, Resolve.fromError(authId, why or ("exit " .. r.status), tern.now()))
		end
		waiting[authId] = nil
		for _, cb in q do
			pcall(cb)
		end
	end)
end

-- Open history blocks --------------------------------------------------------

type Host = { s: State.State, cx: BlockCx, stopped: boolean, warned: boolean }

-- Blocks get no close callback; closed ones are collected.
local live: { [Host]: boolean } = setmetatable({}, { __mode = "k" }) :: any

local dispatch: (h: Host, msg: State.Msg) -> ()

-- Writing ------------------------------------------------------------------

local queue: { string } = {}
local writing = false

local function notify()
	for h in live do
		if not h.stopped then
			dispatch(h, { t = "recorded" })
		end
	end
end

local function flushQueue()
	if writing or #queue == 0 then
		return
	end
	local lines = queue
	queue = {}
	local existing: string? = nil
	if lookup.exists(M.PATH) then
		local ok, text = pcall(tern.fs.read, M.PATH, M.MAX_FILE_BYTES)
		if not ok then
			log.warn("tern-netsuite history: cannot read " .. M.PATH .. "; entry not recorded", tostring(text))
			return
		end
		existing = text
	end
	local text = Store.append(existing, lines, Settings.of(ConfigHost.current()).max_entries)
	writing = true
	-- Whole file to a temporary, then rename: readers never see half of it.
	run(
		{ "/bin/sh", "-c", 'umask 077; cat >"$1.tmp" && mv -f "$1.tmp" "$1"', "tern-netsuite-history", M.PATH },
		{ stdin = text, timeout_ms = M.WRITE_TIMEOUT_MS },
		function(r: ProcessResult)
			writing = false
			if r.status ~= 0 then
				log.warn("tern-netsuite history: write failed", r.stderr)
			end
			notify()
			flushQueue()
		end
	)
end

-- Recording ------------------------------------------------------------------

type Pending = {
	input: Record.Input,
	authId: string?,
	gitDone: boolean,
	authDone: boolean,
	written: boolean,
}

local function normalize(path: string): string
	local p = string.gsub(path, "/+$", "")
	return if p == "" then "/" else p
end

local function finish(p: Pending)
	if p.written then
		return
	end
	p.written = true
	if p.authId then
		p.input.resolution = Resolve.resolve(p.authId, resolveOpts())
	end
	local ok, line = pcall(function()
		return Record.encode(Record.build(p.input))
	end)
	if not ok then
		log.warn("tern-netsuite history: could not build a record", tostring(line))
		return
	end
	table.insert(queue, line)
	flushQueue()
end

local function maybeFinish(p: Pending)
	if p.gitDone and p.authDone then
		finish(p)
	end
end

-- The project the CLI used: the CLI reads project.json from its working
-- directory only, so a deploy from a project's subdirectory has no auth id.
local function contextFor(cwd: string): Context.Context?
	if string.sub(cwd, 1, 1) ~= "/" then
		return nil
	end
	local ctx = Context.forCwd(cwd, lookup)
	if ctx and ctx.projectRoot ~= normalize(cwd) then
		return { projectRoot = ctx.projectRoot, projectName = ctx.projectName, authId = nil, problem = nil }
	end
	return ctx
end

local function paneCwd(pane: number): string?
	local ok, panes = pcall(tern.pane.list)
	if not ok then
		return nil
	end
	for _, p in panes do
		if p.pane == pane then
			return if p.cwd and p.cwd ~= "" then p.cwd else nil
		end
	end
	return nil
end

local function options(cwd: string?): Recognize.Options
	local home = tern.getenv("HOME")
	return {
		cwd = cwd,
		home = if home and home ~= "" then home else nil,
		wrappers = ConfigHost.current().lens.wrappers,
	}
end

type Started = { line: string, cwd: string? }
local started: { [number]: Started } = {}

local function onStarted(ev: CommandStartedEvent)
	local cwd = ev.cwd or paneCwd(ev.pane)
	started[ev.pane] = { line = ev.line, cwd = cwd }
	local m = Recognize.line(ev.line, options(cwd))
	local dir = if m then m.cwd else nil
	local ctx = if dir then contextFor(dir) else nil
	if ctx and ctx.authId then
		lookupAuth(ctx.authId)
	end
end

local function onFinished(ev: CommandFinishedEvent)
	local s = started[ev.pane]
	started[ev.pane] = nil
	local startCwd = if s and s.line == ev.line then s.cwd else paneCwd(ev.pane)
	local m = Recognize.line(ev.line, options(startCwd))
	if m == nil then
		return
	end
	local cwd = m.cwd or paneCwd(ev.pane) or ""
	local ctx = contextFor(cwd)
	local p: Pending = {
		input = {
			finishedAt = os.time(),
			tookMs = ev.took_ms,
			status = ev.status,
			line = ev.line,
			cwd = cwd,
			match = m,
			context = ctx,
			resolution = nil,
			git = nil,
		},
		authId = if ctx then ctx.authId else nil,
		gitDone = false,
		authDone = false,
		written = false,
	}
	tern.timer(M.DEADLINE_MS, function()
		finish(p)
	end)
	if p.authId then
		lookupAuth(p.authId, function()
			p.authDone = true
			maybeFinish(p)
		end)
	else
		p.authDone = true
	end
	if string.sub(cwd, 1, 1) == "/" then
		run(Git.argv(cwd, true), { timeout_ms = M.GIT_TIMEOUT_MS }, function(r: ProcessResult)
			-- A probe cut short still printed what it learned first.
			p.input.git = Git.parse(r.stdout)
			p.gitDone = true
			maybeFinish(p)
		end)
	else
		p.gitDone = true
		maybeFinish(p)
	end
end

-- The block ------------------------------------------------------------------

local exec: (h: Host, effects: { State.Effect }) -> ()

local function warnOnce(h: Host, what: string, err: any)
	if not h.warned then
		h.warned = true
		log.warn("tern-netsuite history " .. what .. " failed", tostring(err))
	end
end

function dispatch(h: Host, msg: State.Msg)
	if h.stopped then
		return
	end
	local ok, err, effects = pcall(State.update, h.s, msg)
	if not ok then
		warnOnce(h, "update " .. msg.t, err)
		return
	end
	exec(h, effects)
	pcall(function()
		h.cx:render()
	end)
end

-- Newest `n` lines of a file; none when it does not exist.
local TAIL = '[ -f "$1" ] || exit 0; tail -n "$2" "$1"'

local function tail(h: Host, path: string, n: number, t: string, gen: number?)
	run({ "/bin/sh", "-c", TAIL, "tern-netsuite-tail", path, tostring(n) }, { timeout_ms = 5000 }, function(r)
		local failed = r.status ~= 0 or r.timed_out
		dispatch(h, {
			t = t,
			gen = gen,
			text = if failed then nil else r.stdout,
			error = if failed then (if r.timed_out then "timed out" else r.stderr) else nil,
		})
	end)
end

function exec(h: Host, effects: { State.Effect })
	for _, e in effects do
		if h.stopped then
			return
		end
		local t = e.t
		if t == "read_local" then
			tail(h, M.PATH, h.s.settings.max_entries, "local", e.gen)
		elseif t == "read_guard" then
			tail(h, M.AUDIT_LOG, State.MAX_GUARD_LINES, "guard", e.gen)
		elseif t == "git" then
			run(Git.argv(e.cwd :: string, false), { timeout_ms = M.GIT_TIMEOUT_MS }, function(r)
				dispatch(h, { t = "git", gen = e.gen, stdout = r.stdout })
			end)
		elseif t == "ci" then
			run(e.argv :: { string }, { timeout_ms = e.timeoutMs, cwd = h.s.cwd, stdin = "" }, function(r)
				dispatch(h, {
					t = "ci",
					gen = e.gen,
					status = r.status,
					stdout = r.stdout,
					stderr = r.stderr,
					timedOut = r.timed_out,
				})
			end)
		elseif t == "open" then
			pcall(function()
				h.cx:open(e.url :: string)
			end)
		elseif t == "log" then
			pcall(function()
				h.cx:open(Link.failedLog(e.repo :: string, e.runId :: number))
			end)
		elseif t == "copy" then
			pcall(function()
				h.cx:copy(e.text :: string)
				h.cx:toast("info", "Copied")
			end)
		elseif t == "exit" then
			h.stopped = true
			live[h] = nil
			h.cx:exit(0)
		end
	end
end

local function format(rows: number): View.Format
	return {
		day = function(at: number): string
			return os.date("%Y-%m-%d %a", at) :: string
		end,
		clock = function(at: number): string
			return os.date("%H:%M", at) :: string
		end,
		-- Room for the filters, CI line, day rules and the dock.
		rows = math.max(5, rows - 10),
	}
end

local function errorView(err: any): BlockView
	return {
		main = {
			k = "col",
			p = { gap = "sm" },
			c = {
				{
					k = "text",
					p = { spans = { { t = "Deploy history could not render: " .. tostring(err), s = "error" } } },
				},
			},
		} :: any,
	}
end

local function guarded(what: string, fn: () -> ())
	local ok, err = pcall(function()
		fn()
	end)
	if not ok then
		log.warn("tern-netsuite history " .. what .. " failed", tostring(err))
	end
end

function M.register()
	tern.on("command_started", function(ev: CommandStartedEvent, _cx: EffectCx)
		guarded("command_started", function()
			onStarted(ev)
		end)
	end)
	tern.on("command_finished", function(ev: CommandFinishedEvent, _cx: EffectCx)
		guarded("command_finished", function()
			onFinished(ev)
		end)
	end)

	tern.block.define("history", {
		init = function(cx: BlockCx, args: { string }, _saved: any): Host
			local cwd = args[1] or cx.cwd
			local s, effects = State.init({
				cwd = if cwd and string.sub(cwd, 1, 1) == "/" then cwd else nil,
				settings = Settings.of(ConfigHost.load().config),
				decode = tern.json.decode,
			})
			local h: Host = { s = s, cx = cx, stopped = false, warned = false }
			live[h] = true
			exec(h, effects)
			return h
		end,
		view = function(h: Host, cx: BlockCx): BlockView
			local ok, v = pcall(View.view, h.s, format(cx.rows))
			if not ok then
				warnOnce(h, "view", v)
				return errorView(v)
			end
			return v :: any
		end,
		title = function(h: Host): string?
			local ok, title = pcall(State.title, h.s)
			return if ok then title else "Deploy history"
		end,
		key = function(h: Host, key: Key, cx: BlockCx): boolean?
			h.cx = cx
			local name = key.name
			-- Shifted letters (G) arrive as their text.
			if key.text and string.match(key.text, "^%g$") and not key.ctrl and not key.meta and not key.alt then
				name = key.text
			end
			if not State.handles(name) then
				return false
			end
			dispatch(h, { t = "key", name = name })
			return true
		end,
		event = function(h: Host, ev: UiEvent, cx: BlockCx)
			h.cx = cx
			if ev.ev == "action" and type(ev.act) == "string" then
				dispatch(h, { t = "action", act = ev.act, value = ev.value })
			end
		end,
	})
end

return M
