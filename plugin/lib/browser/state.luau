--!strict
-- Pure core of the account browser block: lists the objects (`object:list`)
-- and File Cabinet files (`file:list --folder <top folder>`) of the account
-- the project's project.json points at, diffs them against the project and
-- imports a selected entry into it. The host (browser_host.luau) performs
-- the effects and feeds answers back as messages tagged with the run's
-- generation; answers from before a refresh are dropped.
--
-- Every CLI call runs in the project directory: CLI 3.2.0 has no --authid on
-- these commands and takes the auth ID from ./project.json.

local Config = require("../config")
local Diff = require("./diff")
local Imports = require("./imports")
local Listing = require("../sdf/listing")
local Manageauth = require("../account/manageauth")
local Project = require("../sdf/project")
local Resolve = require("../account/resolve")

type Config = Config.Config
type Project = Project.Project
type Entry = Diff.Entry

export type Step = "objects" | "files" | "info" | "dirty"

export type Load = {
	status: "idle" | "loading" | "ok" | "error",
	error: string?,
	objects: { Listing.Object }?,
	files: { string }?,
	-- Output lines the parser could not place.
	unknown: { Listing.Unknown }?,
}

export type Message = { tone: string, text: string }

export type Pending = { token: number, request: Imports.Request, label: string }

export type State = {
	gen: number,
	cwd: string?,
	config: Config?,
	-- "finding" until the project root is known, then "scanning", "ready".
	phase: "finding" | "noproject" | "scanning" | "ready",
	root: string?,
	project: Project?,
	scanError: string?,
	authId: string?,
	target: Resolve.Resolution?,
	cache: Resolve.Cache,
	infoLoading: boolean,
	objects: Load,
	folders: { string },
	files: { [string]: Load },
	entries: { object: { Entry }, file: { Entry } },
	kind: Diff.Kind,
	filter: Diff.Filter,
	editing: boolean,
	selected: number,
	excludeFiles: boolean,
	pending: Pending?,
	importSeq: number,
	-- CLI runs waiting for the one in flight (see pump).
	queue: { Effect },
	-- CLI processes started and not answered yet, any generation.
	inflight: number,
	message: Message?,
}

export type Effect = {
	t: "config" | "find" | "scan" | "run" | "import" | "open" | "exit",
	gen: number,
	cwd: string?,
	root: string?,
	step: Step?,
	folder: string?,
	token: number?,
	argv: { string }?,
	timeoutMs: number?,
	request: Imports.Request?,
	label: string?,
	path: string?,
}

export type Msg =
	{ t: "config", config: Config }
	| { t: "found", gen: number, root: string? }
	| { t: "scanned", gen: number, project: Project?, error: string? }
	| {
		t: "ran",
		gen: number,
		step: Step,
		folder: string?,
		token: number?,
		status: number,
		stdout: string,
		stderr: string,
		timedOut: boolean,
		-- tern.now() when the answer arrived.
		now: number,
	}
	| { t: "key", name: string, text: string?, shift: boolean? }
	| { t: "action", act: string, value: string? }

local M = {}

M.INFO_TIMEOUT_MS = 60000
M.GIT_TIMEOUT_MS = 15000
M.PAGE = 10

local function idle(): Load
	return { status = "idle" }
end

function M.init(args: { cwd: string? }): (State, { Effect })
	local s: State = {
		gen = 1,
		cwd = args.cwd,
		config = nil,
		phase = "finding",
		root = nil,
		project = nil,
		scanError = nil,
		authId = nil,
		target = nil,
		cache = {},
		infoLoading = false,
		objects = idle(),
		folders = {},
		files = {},
		entries = { object = {}, file = {} },
		kind = "object",
		filter = { where = "all", type = nil, query = "" },
		editing = false,
		selected = 1,
		excludeFiles = false,
		pending = nil,
		importSeq = 0,
		queue = {},
		inflight = 0,
		message = nil,
	}
	local effects: { Effect } = { { t = "config", gen = s.gen } }
	if args.cwd then
		table.insert(effects, { t = "find", gen = s.gen, cwd = args.cwd })
	else
		s.phase = "noproject"
	end
	return s, effects
end

local function copy(s: State): State
	return table.clone(s)
end

function M.visible(s: State): { Entry }
	return Diff.apply(s.entries[s.kind], s.filter)
end

function M.selectedEntry(s: State): Entry?
	return M.visible(s)[s.selected]
end

local function clampSelection(s: State)
	local n = #M.visible(s)
	s.selected = math.clamp(s.selected, 1, math.max(n, 1))
end

local function program(s: State): string
	local cfg = s.config
	return if cfg then cfg.suitecloud.program else "suitecloud"
end

local function timeoutMs(s: State): number
	local cfg = s.config
	return if cfg then cfg.suitecloud.timeout_ms else 600000
end

local function resolveTarget(s: State, now: number)
	local cfg, authId = s.config, s.authId
	if cfg and authId then
		s.target = Resolve.resolve(authId, { config = cfg, cache = s.cache, now = now })
	else
		s.target = nil
	end
end

local function recompute(s: State)
	local project = s.project
	if project == nil then
		return
	end
	local objects = if s.objects.status == "ok" then Diff.objects(s.objects.objects or {}, project) else {}
	local okFolders: { string } = {}
	local files: { string } = {}
	for _, folder in s.folders do
		local l = s.files[folder]
		if l and l.status == "ok" then
			table.insert(okFolders, folder)
			table.move(l.files or {}, 1, #(l.files or {}), #files + 1, files)
		end
	end
	local fileEntries = if #okFolders > 0 then Diff.files(files, okFolders, project) else {}
	s.entries = { object = objects, file = fileEntries }
	clampSelection(s)
end

-- One CLI process at a time: concurrent runs for the same auth ID race on
-- its OAuth token refresh, which can void the stored credentials (seen with
-- CLI 3.2.0: "The remote server returned an error:", then every command
-- asking for a browser login). Answers from before a refresh still count
-- here, so a new generation never overlaps an old process.
local function pump(s: State, effects: { Effect })
	if s.inflight > 0 or #s.queue == 0 then
		return
	end
	local queue = table.clone(s.queue)
	local nextRun = table.remove(queue, 1) :: Effect
	s.queue = queue
	s.inflight += 1
	table.insert(effects, nextRun)
end

-- Starts the account listings once both the config and the project are in.
local function start(s: State, effects: { Effect })
	local project, cfg = s.project, s.config
	if project == nil or cfg == nil or s.phase ~= "ready" then
		return
	end
	s.authId = project.defaultAuthId
	s.folders = Diff.folders(project)
	s.files = {}
	s.entries = { object = {}, file = {} }
	s.queue = {}
	if s.authId == nil then
		s.objects = idle()
		s.target = nil
		return
	end
	local authId = s.authId :: string
	resolveTarget(s, 0)
	local cwd = project.root
	local queue: { Effect } = {}
	if Resolve.needsLookup(authId, { config = cfg, cache = s.cache, now = 0 }) then
		s.infoLoading = true
		table.insert(queue, {
			t = "run",
			gen = s.gen,
			step = "info",
			argv = { program(s), "account:manageauth", "--info", authId },
			cwd = cwd,
			timeoutMs = M.INFO_TIMEOUT_MS,
		})
	end
	s.objects = { status = "loading" }
	table.insert(queue, {
		t = "run",
		gen = s.gen,
		step = "objects",
		argv = { program(s), "object:list" },
		cwd = cwd,
		timeoutMs = timeoutMs(s),
	})
	local files: { [string]: Load } = {}
	for _, folder in s.folders do
		files[folder] = { status = "loading" }
		table.insert(queue, {
			t = "run",
			gen = s.gen,
			step = "files",
			folder = folder,
			argv = { program(s), "file:list", "--folder", folder },
			cwd = cwd,
			timeoutMs = timeoutMs(s),
		})
	end
	s.files = files
	s.queue = queue
	pump(s, effects)
end

M.REAUTH_MARKER = "Starting the browser-based authentication"

local function failure(s: State, status: number, stdout: string, stderr: string, timedOut: boolean): string
	if string.find(stdout .. stderr, M.REAUTH_MARKER, 1, true) then
		return string.format(
			"the CLI wants a browser login for auth ID %s (its credentials expired); finish it, or run a suitecloud command in %s in a terminal, then press r",
			s.authId or "?",
			s.root or "the project"
		)
	end
	if timedOut then
		return string.format("timed out after %d s (suitecloud.timeout_ms)", math.floor(timeoutMs(s) / 1000))
	end
	local why = Listing.errorText(Listing.split(stderr .. "\n" .. stdout))
	return why or ("exited " .. status .. " without output")
end

local function listed(s: State, msg: any): Load
	if msg.status ~= 0 or msg.timedOut then
		return { status = "error", error = failure(s, msg.status, msg.stdout, msg.stderr, msg.timedOut) }
	end
	local lines = Listing.split(msg.stdout)
	if msg.step == "objects" then
		local r = Listing.objects(lines, msg.status)
		if r == nil then
			return { status = "error", error = failure(s, msg.status, msg.stdout, msg.stderr, false) }
		end
		return { status = "ok", objects = r.objects, unknown = r.unknown }
	end
	local r = Listing.files(lines, msg.status)
	if r == nil then
		return { status = "error", error = failure(s, msg.status, msg.stdout, msg.stderr, false) }
	end
	return { status = "ok", files = r.files, unknown = r.unknown }
end

local function targetLabel(s: State): string
	local t = s.target
	if t == nil then
		return "unknown account"
	end
	if t.source == "unknown" then
		return t.authId .. " (account unknown)"
	end
	return (t.accountId or t.label) .. (if t.production then " PROD" else "")
end

local function onInfo(s: State, msg: any)
	s.infoLoading = false
	local authId = s.authId
	if authId == nil then
		return
	end
	local info = if msg.status == 0 then Manageauth.parseInfo(Manageauth.lines(msg.stdout)) else nil
	if info and info.accountId then
		s.cache = Resolve.store(s.cache, { authId = authId, accountId = info.accountId, at = msg.now, error = nil })
	else
		local why = if msg.timedOut
			then "timed out"
			else Manageauth.errorText(Manageauth.lines(msg.stderr .. "\n" .. msg.stdout))
		s.cache = Resolve.store(s.cache, Resolve.fromError(authId, why or ("exit " .. msg.status), msg.now))
	end
	resolveTarget(s, msg.now)
end

local function startImport(s: State, request: Imports.Request, forced: boolean, effects: { Effect })
	local project = s.project :: Project
	local label = project.name .. " <- " .. targetLabel(s)
	table.insert(effects, { t = "import", gen = s.gen, request = request, label = label })
	local what = request.scriptId or request.path or "?"
	s.message = {
		tone = if forced then "warning" else "info",
		text = string.format(
			"Importing %s into %s in a split below%s; press r to refresh when it finishes",
			what,
			project.name,
			if forced then " (forced: local changes may be overwritten)" else ""
		),
	}
end

local function onDirty(s: State, msg: any, effects: { Effect })
	local p = s.pending
	if p == nil or msg.token ~= p.token then
		return
	end
	s.pending = nil
	local ok, why = Imports.verdict(Imports.dirty(msg.status, msg.stdout, msg.stderr, msg.timedOut), false)
	if ok then
		startImport(s, p.request, false, effects)
	else
		s.message = { tone = "warning", text = "Import refused: " .. why }
	end
end

local function importSelected(s: State, force: boolean, effects: { Effect })
	local project = s.project
	local e = M.selectedEntry(s)
	if project == nil or e == nil then
		s.message = { tone = "muted", text = "Nothing selected" }
		return
	end
	local request, err = Imports.forEntry(project, e, s.excludeFiles)
	if request == nil then
		s.message = { tone = "muted", text = err or "Nothing to import" }
		return
	end
	local _, invalid = Imports.argv(program(s), request)
	if invalid then
		s.message = { tone = "error", text = "Cannot import " .. e.id .. ": " .. invalid }
		return
	end
	s.importSeq += 1
	if force then
		s.pending = nil
		startImport(s, request, true, effects)
		return
	end
	s.pending = { token = s.importSeq, request = request, label = e.id }
	s.message = { tone = "muted", text = "Checking for uncommitted changes where " .. e.id .. " would be written…" }
	table.insert(effects, {
		t = "run",
		gen = s.gen,
		step = "dirty",
		token = s.importSeq,
		argv = Imports.dirtyArgv(request, Imports.destinations(request, e.fileReferences)),
		cwd = request.root,
		timeoutMs = M.GIT_TIMEOUT_MS,
	})
end

local function refresh(s: State, effects: { Effect })
	s.gen += 1
	s.pending = nil
	s.message = nil
	s.objects = idle()
	s.files = {}
	s.queue = {}
	s.entries = { object = {}, file = {} }
	if s.root then
		s.phase = "scanning"
		table.insert(effects, { t = "scan", gen = s.gen, root = s.root })
	elseif s.cwd then
		s.phase = "finding"
		table.insert(effects, { t = "find", gen = s.gen, cwd = s.cwd })
	end
end

local function setFilter(s: State, f: Diff.Filter)
	s.filter = f
	s.selected = 1
end

local function move(s: State, delta: number)
	s.selected += delta
	clampSelection(s)
end

local function printable(msg: any): string?
	local text = msg.text
	if type(text) == "string" and #text >= 1 and not string.find(text, "%c") then
		return text
	end
	return nil
end

local function editKey(s: State, msg: any): boolean
	local name = msg.name
	if name == "escape" or name == "enter" or name == "return" then
		s.editing = false
	elseif name == "backspace" then
		local q = s.filter.query
		setFilter(s, { where = s.filter.where, type = s.filter.type, query = string.sub(q, 1, -2) })
	elseif name == "down" then
		move(s, 1)
	elseif name == "up" then
		move(s, -1)
	else
		local ch = printable(msg)
		if ch == nil then
			return false
		end
		setFilter(s, { where = s.filter.where, type = s.filter.type, query = s.filter.query .. ch })
	end
	return true
end

local function upper(msg: any, letter: string): boolean
	return msg.name == string.upper(letter) or (msg.name == letter and msg.shift == true)
end

local function key(s: State, msg: any, effects: { Effect }): boolean
	if s.editing then
		return editKey(s, msg)
	end
	local name = msg.name
	local n = #M.visible(s)
	if name == "escape" then
		if s.filter.query ~= "" then
			setFilter(s, { where = s.filter.where, type = s.filter.type, query = "" })
		else
			table.insert(effects, { t = "exit", gen = s.gen })
		end
	elseif name == "q" and not msg.shift then
		table.insert(effects, { t = "exit", gen = s.gen })
	elseif name == "/" then
		s.editing = true
	elseif name == "down" or name == "j" then
		move(s, 1)
	elseif name == "up" or name == "k" then
		move(s, -1)
	elseif name == "pagedown" then
		move(s, M.PAGE)
	elseif name == "pageup" then
		move(s, -M.PAGE)
	elseif name == "home" or (name == "g" and not msg.shift) then
		s.selected = 1
	elseif name == "end" or upper(msg, "g") then
		s.selected = math.max(n, 1)
	elseif name == "tab" then
		s.kind = if s.kind == "object" then "file" else "object"
		setFilter(s, { where = s.filter.where, type = nil, query = s.filter.query })
	elseif name == "a" and not msg.shift then
		setFilter(s, { where = Diff.nextWhere(s.filter.where), type = s.filter.type, query = s.filter.query })
	elseif upper(msg, "t") or (name == "t") then
		local step = if upper(msg, "t") then -1 else 1
		local types = Diff.types(s.entries[s.kind])
		setFilter(
			s,
			{ where = s.filter.where, type = Diff.nextType(types, s.filter.type, step), query = s.filter.query }
		)
	elseif name == "x" and not msg.shift then
		s.excludeFiles = not s.excludeFiles
		s.message = {
			tone = "muted",
			text = if s.excludeFiles
				then "Object imports skip referenced script files (--excludefiles)"
				else "Object imports also import referenced script files",
		}
	elseif name == "r" and not msg.shift then
		refresh(s, effects)
	elseif upper(msg, "i") then
		importSelected(s, true, effects)
	elseif name == "i" then
		importSelected(s, false, effects)
	elseif name == "enter" or name == "return" then
		local e = M.selectedEntry(s)
		if e and e.localPath and s.root then
			table.insert(effects, { t = "open", gen = s.gen, path = (s.root :: string) .. "/" .. e.localPath })
		end
	else
		return false
	end
	return true
end

local function action(s: State, msg: any, effects: { Effect })
	local act, value = msg.act, msg.value or ""
	if act == "kind" and (value == "object" or value == "file") then
		s.kind = value
		setFilter(s, { where = s.filter.where, type = nil, query = s.filter.query })
	elseif act == "where" and (value == "all" or value == "account" or value == "both" or value == "local") then
		setFilter(s, { where = value, type = s.filter.type, query = s.filter.query })
	elseif act == "type" then
		local types = Diff.types(s.entries[s.kind])
		local ty = if value == "all"
			then nil
			else Diff.nextType(types, s.filter.type, if value == "prev" then -1 else 1)
		setFilter(s, { where = s.filter.where, type = ty, query = s.filter.query })
	elseif act == "sel" then
		local i = tonumber(value)
		if i then
			s.selected = math.floor(i)
			clampSelection(s)
		end
	elseif act == "search" then
		s.editing = true
	elseif act == "refresh" then
		refresh(s, effects)
	elseif act == "exclude" then
		s.excludeFiles = not s.excludeFiles
	elseif act == "import" then
		importSelected(s, value == "force", effects)
	end
end

function M.update(prev: State, msg: Msg): (State, { Effect })
	local s = copy(prev)
	local effects: { Effect } = {}
	local m: any = msg
	if m.t == "config" then
		s.config = m.config
		start(s, effects)
	elseif m.t == "found" then
		if m.gen ~= s.gen then
			return prev, {}
		end
		s.root = m.root
		if m.root == nil then
			s.phase = "noproject"
		else
			s.phase = "scanning"
			table.insert(effects, { t = "scan", gen = s.gen, root = m.root })
		end
	elseif m.t == "scanned" then
		if m.gen ~= s.gen then
			return prev, {}
		end
		if m.project == nil then
			s.phase = "noproject"
			s.scanError = m.error or "the project could not be read"
		else
			s.project = m.project
			s.scanError = nil
			s.phase = "ready"
			start(s, effects)
		end
	elseif m.t == "ran" then
		local cli = m.step ~= "dirty"
		if cli then
			s.inflight = math.max(s.inflight - 1, 0)
		end
		if m.gen == s.gen then
			if m.step == "info" then
				onInfo(s, m)
			elseif m.step == "dirty" then
				onDirty(s, m, effects)
			elseif m.step == "objects" then
				s.objects = listed(s, m)
				recompute(s)
			elseif m.step == "files" and m.folder and s.files[m.folder] then
				local files = table.clone(s.files)
				files[m.folder] = listed(s, m)
				s.files = files
				recompute(s)
			end
		elseif not cli then
			return prev, {}
		end
		if cli then
			pump(s, effects)
		end
	elseif m.t == "key" then
		if not key(s, m, effects) then
			return prev, {}
		end
	elseif m.t == "action" then
		action(s, m, effects)
	end
	return s, effects
end

-- What `save` persists: enough to reopen on the same directory.
function M.saved(s: State): { cwd: string? }
	return { cwd = s.cwd }
end

return M
