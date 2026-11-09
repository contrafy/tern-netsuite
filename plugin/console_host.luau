--!strict
-- Host half of the SuiteQL console: the `console` block. Runs the effects
-- of lib/console/state.luau (SuiteQL through NsHost, the history and saved
-- query files in plugin data, the read-only .sql folders, clipboard,
-- exports, the record inspector) and feeds results back as messages.
-- Query results arrive in NsHost callbacks; late ones of a closed block
-- only re-render nothing (Tern ignores renders of a pane without a block).

local ConfigHost = require("./config_host")
local Export = require("./lib/console/export")
local InspectLink = require("./lib/inspector/link")
local Library = require("./lib/console/library")
local NsHost = require("./ns_host")
local Pane = require("./lib/pane")
local State = require("./lib/console/state")
local Store = require("./lib/console/store")
local View = require("./lib/console/view")

local log = tern.log

type Host = { s: State.State, cx: BlockCx, warned: boolean, resized: boolean, drawn: boolean }

local M = {}

M.LAST_CONNECTION_KEY = "console.connection"
-- Result files opened in Tern's table viewer; older ones are removed.
M.KEEP_VIEWED = 20

local seed = string.format("console:%d:%.6f:%.17g:%s", os.time(), os.clock(), math.random(), tostring({}))
local counter = 0

local function dataDir(): string
	return tern.plugin.data .. "/" .. Store.DIR
end

local function warnOnce(h: Host, what: string, err: any)
	if not h.warned then
		h.warned = true
		log.warn("tern-netsuite console " .. what .. " failed", tostring(err))
	end
end

local function readFile(path: string, max: number): string?
	local ok, text = pcall(tern.fs.read, path, max)
	return if ok and type(text) == "string" then text else nil
end

local function exists(path: string): boolean
	local ok, present = pcall(tern.fs.exists, path)
	return ok and present == true
end

-- Writes `text` to `path` (creating `dir`); nil or why not.
local function writeFile(dir: string, path: string, text: string): string?
	local ok, err = pcall(function()
		tern.fs.mkdir(dir)
		tern.fs.write(path, text)
	end)
	return if ok then nil else tostring(err)
end

local fs: Library.Fs = {
	list = function(dir: string): { string }?
		local ok, names = pcall(tern.fs.list, dir)
		return if ok and type(names) == "table" then names else nil
	end,
	read = readFile,
}

local function loadSaved(): { Store.Saved }
	return Store.parseSaved(readFile(dataDir() .. "/" .. Store.SAVED_FILE, Store.MAX_FILE_BYTES), tern.json.decode)
end

local function loadData(): State.Data
	local ok, last = pcall(tern.kv.get, M.LAST_CONNECTION_KEY)
	return {
		history = Store.parseHistory(
			readFile(dataDir() .. "/" .. Store.HISTORY_FILE, Store.MAX_FILE_BYTES),
			tern.json.decode
		),
		saved = loadSaved(),
		lastConnection = if ok and type(last) == "string" then last else nil,
	}
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
	pcall(function()
		h.cx:render()
	end)
end

local function tell(h: Host, tone: string, text: string)
	dispatch(h, { t = "notice", tone = tone, notice = text })
	rerender(h)
end

local function query(h: Host, e: State.Effect)
	local started = tern.now()
	NsHost.query(
		e.connection :: string,
		e.sql :: string,
		nil,
		{ cx = h.cx, max_rows = e.max_rows },
		function(result: NsHost.Result?, err)
			dispatch(h, {
				t = "result",
				req = e.req,
				rows = if result then result.rows else nil,
				truncated = if result then result.truncated else nil,
				pages = if result then result.pages else nil,
				ms = if result then result.ms else nil,
				elapsed = tern.now() - started,
				at = os.date("%H:%M:%S"),
				err = err,
			})
			rerender(h)
		end
	)
end

-- Appends to the history file (merging what other consoles wrote) and
-- remembers the connection for the next console.
local function remember(e: State.Effect)
	local path = dataDir() .. "/" .. Store.HISTORY_FILE
	local list = Store.parseHistory(readFile(path, Store.MAX_FILE_BYTES), tern.json.decode)
	list = Store.addHistory(list, { sql = e.sql :: string, connection = e.connection, at = os.time() })
	local err = writeFile(dataDir(), path, Store.encodeHistory(list, tern.json.encode))
	if err then
		log.warn("tern-netsuite console history write failed", err)
	end
	pcall(tern.kv.set, M.LAST_CONNECTION_KEY, e.connection)
end

local function list(h: Host, e: State.Effect)
	local dirs = ConfigHost.current().console.saved_dirs
	local files, problems = Library.gather(fs, exists, dirs, e.cwd or h.cx.cwd, tern.getenv("HOME"))
	dispatch(h, { t = "listed", saved = loadSaved(), files = files, problems = problems })
end

local function readQuery(h: Host, e: State.Effect)
	local path = e.path :: string
	local text = readFile(path, Library.MAX_SQL_FILE_BYTES)
	if text == nil then
		local why = if exists(path)
			then string.format("larger than %d KB or not a readable file", Library.MAX_SQL_FILE_BYTES // 1024)
			else "it does not exist"
		dispatch(h, { t = "loaded", path = path, notice = string.format("Could not load %s: %s.", path, why) })
		return
	end
	dispatch(h, { t = "loaded", path = path, text = text, run = e.run })
end

local function store(h: Host, e: State.Effect, remove: boolean)
	local path = dataDir() .. "/" .. Store.SAVED_FILE
	local saved = loadSaved()
	local name = e.name :: string
	local updated: { Store.Saved }?, why: string?
	if remove then
		updated = Store.remove(saved, name)
	else
		updated, why = Store.save(saved, name, e.sql or "", os.time())
	end
	if updated == nil then
		dispatch(h, { t = "stored", saved = saved, tone = "warning", notice = "Not saved: " .. (why or "?") })
		return
	end
	local err = writeFile(dataDir(), path, Store.encodeSaved(updated, tern.json.encode))
	if err then
		dispatch(h, { t = "stored", saved = saved, tone = "error", notice = "Could not write " .. path .. ": " .. err })
		return
	end
	dispatch(h, {
		t = "stored",
		saved = updated,
		tone = "success",
		notice = if remove then string.format("Deleted %q.", name) else string.format("Saved as %q.", name),
	})
end

-- Removes all but the newest KEEP_VIEWED result files.
local function prune(dir: string)
	local names = fs.list(dir)
	if names == nil then
		return
	end
	local stamped: { { string } } = {}
	for _, n in names do
		local stamp = string.match(n, "(%d%d%d%d%d%d%d%d%-%d%d%d%d%d%d)")
		if stamp and string.sub(n, 1, 8) == "suiteql-" then
			table.insert(stamped, { stamp .. n, n })
		end
	end
	table.sort(stamped, function(a: { string }, b: { string }): boolean
		return a[1] > b[1]
	end)
	for i = M.KEEP_VIEWED + 1, #stamped do
		pcall(tern.fs.remove, dir .. "/" .. stamped[i][2])
	end
end

local function export(h: Host, e: State.Effect)
	local format: Export.Format = e.format :: Export.Format
	local text = e.text :: string
	local what = string.upper(format)
	if e.how == "copy" then
		h.cx:copy(text)
		tell(h, "success", string.format("Copied the rows as %s.", what))
		return
	end
	local dir: string?
	if e.how == "view" then
		dir = dataDir() .. "/results"
	else
		dir = e.cwd or h.cx.cwd
	end
	if dir == nil or not Export.safePath(dir) then
		tell(h, "error", "Not saved: the console does not know the pane's folder; open it from a pane with one.")
		return
	end
	local stamp = os.date("%Y%m%d-%H%M%S")
	local path = ""
	for n = 1, 100 do
		path = dir .. "/" .. Export.fileName(e.connection or "suiteql", stamp, format, n)
		if not exists(path) then
			break
		end
	end
	local err = if exists(path) then "too many files of that name" else writeFile(dir, path, text)
	if err then
		tell(h, "error", string.format("Could not write %s: %s", path, err))
		return
	end
	if e.how == "view" then
		prune(dir)
	end
	-- A path opens through the window's routes: Tern shows .csv and .tsv
	-- in its table viewer, .json in an editor.
	h.cx:open(path)
	tell(h, "success", if e.how == "view" then "Opened in Tern's table viewer: " .. path else "Saved " .. path)
end

local function inspect(h: Host, e: State.Effect)
	counter += 1
	local url = InspectLink.url({ connection = e.connection, type = e.type, id = e.id })
	local start, grants, err =
		InspectLink.grantStart(url, tern.kv.get(InspectLink.GRANTS_KEY), InspectLink.newId(seed, counter), os.time())
	if start == nil then
		tell(h, "error", "Cannot inspect this record: " .. (err or "?"))
		return
	end
	tern.kv.set(InspectLink.GRANTS_KEY, grants)
	h.cx:open(start)
end

local function focus(h: Host, e: State.Effect)
	local op: { any } = { "focus", if e.id then e.id else tern.json.null }
	if h.drawn then
		pcall(function()
			h.cx:frame({ op })
		end)
		return
	end
	-- The first view is not drawn yet: Tern focuses only drawn nodes.
	tern.timer(50, function()
		pcall(function()
			h.cx:frame({ op })
		end)
	end)
end

function exec(h: Host, effects: { State.Effect })
	for _, e in effects do
		local ok, err = pcall(function()
			if e.t == "query" then
				query(h, e)
			elseif e.t == "history" then
				remember(e)
			elseif e.t == "list" then
				list(h, e)
			elseif e.t == "read" then
				readQuery(h, e)
			elseif e.t == "store" then
				store(h, e, false)
			elseif e.t == "delete" then
				store(h, e, true)
			elseif e.t == "export" then
				export(h, e)
			elseif e.t == "inspect" then
				inspect(h, e)
			elseif e.t == "open" then
				-- window.luau routes tern-netsuite://logs/connect to the connect block.
				h.cx:open(e.url or "")
			elseif e.t == "focus" then
				focus(h, e)
			end
		end)
		if not ok then
			log.warn("tern-netsuite console " .. e.t .. " failed", tostring(err))
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
					p = { spans = { { t = "The SuiteQL console could not render: " .. tostring(err), s = "error" } } },
				},
			},
		} :: any,
	}
end

function M.register()
	tern.block.define(
		"console",
		{
			init = function(cx: BlockCx, args: { string }, saved: any): Host
				local snap = ConfigHost.load()
				-- Without a cwd arg (opened from the block palette) the pane's own.
				local launch = args
				local hasCwd = false
				for _, a in args do
					hasCwd = hasCwd or string.sub(a, 1, 4) == "cwd="
				end
				if cx.cwd and not hasCwd then
					launch = table.clone(args)
					table.insert(launch, 1, "cwd=" .. cx.cwd)
				end
				local s, effects = State.init(launch, saved, snap.config, { null = tern.json.null }, loadData())
				local h: Host = { s = s, cx = cx, warned = false, resized = false, drawn = false }
				exec(h, effects)
				return h
			end,
			view = function(h: Host, cx: BlockCx): BlockView
				h.drawn = true
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
				return if ok then title else "SuiteQL console"
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
				if ev.ev == "focus" and type(ev.id) == "string" then
					dispatch(h, { t = "focus", id = ev.id })
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
