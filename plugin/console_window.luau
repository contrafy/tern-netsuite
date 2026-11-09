--!strict
-- Window half of the SuiteQL console: the palette commands and the
-- `console` link area (lib/console/link.luau).
--   - "SuiteQL console" opens the block beside the focused pane, in its
--     folder (saved_dirs resolve in its repository, exports land there).
--   - "Run SuiteQL file" runs the focused file block's .sql file in a new
--     console; without one it offers saved queries and the .sql files of
--     config console.saved_dirs in a picker. The console runs it at once
--     unless its connection is production (then it waits for Ctrl+Enter).
--   - `tern-netsuite://console?...` opens a console with a .sql file
--     loaded and never runs anything (any program can print such a link).
-- The picker reads the plugin data and folders of this machine; consoles
-- read their own host's (the same machine for local panes).

local lazy = require("./lib/lazy")
local ConfigHost = require("./config_host")
local Library = lazy(function()
	return require("./lib/console/library")
end)
local Link = lazy(function()
	return require("./lib/console/link")
end)
local Store = lazy(function()
	return require("./lib/console/store")
end)

local M = {}

-- `cx:pick` (Tern 0.9.13) is not in the pinned type definitions yet.
type Awaitable = { next: (self: Awaitable, fn: (result: any, err: string?, cx: WindowCx?) -> ()) -> () }
type Picker = { pick: (self: Picker, opts: { [string]: any }) -> Awaitable }

local function dirname(path: string): string
	return string.match(path, "^(.*)/[^/]*$") or "/"
end

local function absolute(path: string?): string?
	return if path and string.sub(path, 1, 1) == "/" and not string.find(path, "%c") then path else nil
end

local function paneInfo(cx: WindowCx, pane: number?): PaneInfo?
	local id = if pane and pane ~= 0 then pane else cx.session:focused()
	return if id then cx.session:pane(id) else nil
end

-- The folder of a pane: its cwd, or a file block's directory.
local function paneDir(info: PaneInfo?): string?
	if info == nil then
		return nil
	end
	local cwd = absolute(info.cwd)
	if cwd and cwd ~= "" then
		return cwd
	end
	local path = absolute(info.path)
	return if path then dirname(path) else nil
end

local function open(cx: WindowCx, launch: { [string]: any })
	if cx:new_block(Link().BLOCK, Link().toArgs(launch :: any), "beside") == nil then
		cx:toast("error", "Tern NetSuite: the console block is not available on this host")
	end
end

local function exists(path: string): boolean
	local ok, present = pcall(tern.fs.exists, path)
	return ok and present == true
end

local function readFile(path: string, max: number): string?
	local ok, text = pcall(tern.fs.read, path, max)
	return if ok and type(text) == "string" then text else nil
end

local fs = {
	list = function(dir: string): { string }?
		local ok, names = pcall(tern.fs.list, dir)
		return if ok and type(names) == "table" then names else nil
	end,
	read = readFile,
}

local function pickQuery(cx: WindowCx, cwd: string?)
	local store = Store()
	local saved = store.parseSaved(
		readFile(tern.plugin.data .. "/" .. store.DIR .. "/" .. store.SAVED_FILE, store.MAX_FILE_BYTES),
		tern.json.decode
	)
	local files, problems =
		Library().gather(fs, exists, ConfigHost.current().console.saved_dirs, cwd, tern.getenv("HOME"))
	local items = Library().items(saved, files)
	if #items == 0 then
		cx:toast(
			"info",
			"Tern NetSuite: no SuiteQL query to run",
			if #problems > 0
				then problems[1]
				else "Focus a .sql file, save a query in the console (Ctrl+S) or list folders in console.saved_dirs"
		)
		return
	end
	local choices: { { [string]: any } } = {}
	for _, it in items do
		table.insert(choices, {
			label = it.label,
			detail = it.detail,
			group = if it.kind == "saved" then "Saved queries" else "Query folders",
			icon = if it.kind == "saved" then "database" else "code",
			name = it.name,
			path = it.path,
		})
	end
	local picker = (cx :: any) :: Picker
	picker
		:pick({ items = choices, placeholder = "Run a saved query or .sql file", icon = "database", action = "run" })
		:next(function(choice: any, err: string?, fresh: WindowCx?)
			local at = fresh or cx
			if type(choice) ~= "table" then
				if err then
					at:toast("error", "Tern NetSuite: no query run", err)
				end
				return
			end
			if type(choice.path) == "string" then
				open(at, { cwd = cwd, file = choice.path, run = true })
			elseif type(choice.name) == "string" then
				open(at, { cwd = cwd, saved = choice.name, run = true })
			end
		end)
end

-- Handles `tern-netsuite://console...`; window.luau dispatches area
-- "console" here.
function M.route(link: LinkRequest, cx: WindowCx): RouteDecision?
	local decision, err = Link().route(link.url, paneDir(paneInfo(cx, link.pane)))
	if decision == nil then
		cx:toast("error", "Tern NetSuite: invalid console link", err)
		return { handled = true }
	end
	return { block = decision.block, args = decision.args }
end

function M.register()
	tern.command({
		id = "console",
		title = "Tern NetSuite: SuiteQL console",
		icon = "database",
		run = function(cx: WindowCx)
			open(cx, { cwd = paneDir(paneInfo(cx, nil)) })
		end,
	})
	tern.command({
		id = "console-run-file",
		title = "Tern NetSuite: Run SuiteQL file",
		icon = "database",
		run = function(cx: WindowCx)
			local info = paneInfo(cx, nil)
			local path = if info and info.kind == "file" then absolute(info.path) else nil
			if path and Link().validFile(path) then
				open(cx, { cwd = dirname(path), file = path, run = true })
				return
			end
			pickQuery(cx, paneDir(info))
		end,
	})
end

return M
