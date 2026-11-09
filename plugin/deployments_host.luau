--!strict
-- Host half of the script deployments view: the `deployments` block. Runs
-- the effects of lib/deployments/state.luau (SuiteQL through NsHost, the
-- local project scan, reading and writing the object file of an edit,
-- links, clipboard) and feeds results, keys and clicks back as messages.
-- Nothing here writes to NetSuite: the only write is the local object file
-- an edit previewed, through State.WRITE_SCRIPT.

local ConfigHost = require("./config_host")
local Context = require("./lib/account/context")
local LogsLink = require("./lib/monitor/logs/link")
local NsHost = require("./ns_host")
local Pane = require("./lib/pane")
local ProjectHost = require("./project_host")
local State = require("./lib/deployments/state")
local View = require("./lib/deployments/view")

local log = tern.log

type Host = { s: State.State, cx: BlockCx, stopped: boolean, warned: boolean, resized: boolean }

local M = {}

local seed = string.format("deployments:%d:%.6f:%.17g:%s", os.time(), os.clock(), math.random(), tostring({}))
local counter = 0

local function warnOnce(h: Host, what: string, err: any)
	if not h.warned then
		h.warned = true
		log.warn("tern-netsuite deployments " .. what .. " failed", tostring(err))
	end
end

local exec: (h: Host, effects: { State.Effect }) -> ()

local function rerender(h: Host)
	if not h.stopped then
		pcall(function()
			h.cx:render()
		end)
	end
end

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

-- A result from a callback: apply it and render.
local function deliver(h: Host, msg: State.Msg)
	if h.stopped then
		return
	end
	if dispatch(h, msg) then
		rerender(h)
	end
end

local function exists(path: string): boolean
	local ok, present = pcall(tern.fs.exists, path)
	return ok and present == true
end

local function query(h: Host, e: State.Effect)
	NsHost.query(
		e.connection :: string,
		e.sql :: string,
		{},
		{ cx = h.cx, max_rows = e.max_rows },
		function(result: NsHost.Result?, err)
			deliver(h, {
				t = "result",
				req = e.req,
				rows = if result then result.rows else nil,
				truncated = if result then result.truncated else nil,
				err = err,
				at = os.date("%H:%M:%S"),
			})
		end
	)
end

local function projects(h: Host, roots: { string }, errors: { string })
	ProjectHost.projects(roots, nil, function(found, failed)
		for _, f in failed do
			table.insert(errors, f.root .. ": " .. f.message)
		end
		deliver(h, { t = "scanned", projects = found, errors = errors })
	end)
end

-- The project containing cwd, else every project of its repository.
local function scan(h: Host, cwd: string?)
	if cwd == nil then
		deliver(h, { t = "scanned", projects = {}, errors = {} })
		return
	end
	local root = Context.findRoot(cwd, exists)
	if root then
		projects(h, { root }, {})
		return
	end
	local repo = Context.repoRoot(cwd, exists)
	if repo == nil then
		deliver(h, { t = "scanned", projects = {}, errors = {} })
		return
	end
	local roots = ConfigHost.current().projects.roots
	ProjectHost.discover(repo, if #roots > 0 then roots else nil, function(found, err)
		projects(h, found, if err then { err } else {})
	end)
end

-- Read in a process callback, not inline: the state hashes and parses the
-- file, which must not run inside the key handler that asked for it.
local function read(h: Host, e: State.Effect)
	local ok, err = pcall(function()
		tern.process.run({ "/bin/cat", "--", e.path :: string }, { timeout_ms = 10000 }, function(r: ProcessResult)
			local good = r.status == 0 and not r.timed_out
			deliver(h, {
				t = "read",
				req = e.req,
				text = if good then r.stdout else nil,
				error = if good
					then nil
					else (string.match(r.stderr, "^%s*([^\n]+)") or string.format("cat exited %d", r.status)),
			})
		end)
	end)
	if not ok then
		deliver(h, { t = "read", req = e.req, error = tostring(err) })
	end
end

local function write(h: Host, e: State.Effect)
	local ok, err = pcall(function()
		tern.process.run(
			{ "/bin/sh", "-c", State.WRITE_SCRIPT, "tern-netsuite-edit", e.path :: string, e.expect :: string },
			{ stdin = e.text, timeout_ms = 10000 },
			function(r: ProcessResult)
				deliver(h, {
					t = "wrote",
					req = e.req,
					error = if r.timed_out then "Writing the file timed out." else State.writeError(r.status, r.stderr),
				})
			end
		)
	end)
	if not ok then
		deliver(h, { t = "wrote", req = e.req, error = "The file could not be written: " .. tostring(err) })
	end
end

-- Opens the execution log tail of a script with a single-use grant, so it
-- starts without the held step a printed link gets.
local function logs(h: Host, url: string)
	counter += 1
	local id = LogsLink.newId(seed, counter)
	local ok, err = pcall(function()
		local start, grants, why = LogsLink.grantStart(url, tern.kv.get(LogsLink.GRANTS_KEY), id, os.time())
		if start == nil or grants == nil then
			error(why or "not a tail link")
		end
		tern.kv.set(LogsLink.GRANTS_KEY, grants)
		h.cx:open(start)
	end)
	if not ok then
		pcall(function()
			h.cx:toast("error", "Tern NetSuite: logs not opened", tostring(err))
		end)
	end
end

function exec(h: Host, effects: { State.Effect })
	for _, e in effects do
		if h.stopped then
			return
		end
		if e.t == "query" then
			query(h, e)
		elseif e.t == "scan" then
			scan(h, e.cwd)
		elseif e.t == "read" then
			read(h, e)
		elseif e.t == "write" then
			write(h, e)
		elseif e.t == "open" then
			-- An https page opens in the browser; tern-netsuite:// links route
			-- through the window.
			pcall(function()
				h.cx:open(e.url or "")
			end)
		elseif e.t == "logs" then
			logs(h, e.url or "")
		elseif e.t == "copy" then
			pcall(function()
				h.cx:copy(e.text or "")
				h.cx:toast("info", "Tern NetSuite: copied", e.text)
			end)
		elseif e.t == "focus" then
			pcall(function()
				h.cx:frame({ { "focus", e.id or State.FILTER_INPUT } })
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
					p = { spans = { { t = "The deployments view could not render: " .. tostring(err), s = "error" } } },
				},
			},
		} :: any,
	}
end

function M.register()
	tern.block.define(
		"deployments",
		{
			init = function(cx: BlockCx, args: { string }, saved: any): Host
				local snap = ConfigHost.load()
				local s, effects = State.init(args, saved, snap.config, cx.cwd)
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
				return if ok then title else "NetSuite deployments"
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
