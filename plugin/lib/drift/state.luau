--!strict
-- Pure core of the drift block: compares the SDF project of a directory
-- with an account. The account is only read: its copies of the project's
-- objects (`object:import`) and File Cabinet files (`file:import`) are
-- imported into a scratch project (scratch.luau) under the plugin's data
-- directory, never into the user's project, and compared there; a key adds
-- the account's other objects under the project's script id prefixes
-- (`object:list`, listed only). The host (drift_host.luau) performs the
-- effects and feeds answers back tagged with the generation (a new target
-- or project) and the run number; stale answers are dropped.
--
-- Account commands carry `slot` (the auth ID) and run one at a time, each
-- in that auth ID's machine-wide CLI slot (lib/sdf/cli_slot.luau). A run
-- cannot kill the command in flight: cancel drops the queue and ignores the
-- answer, and the scratch directory goes once nothing writes into it.
--
-- The target is project.json's defaultAuthId unless the picker chose
-- another auth ID (configured accounts' auth_ids and `account:manageauth
-- --list`). The last complete result per project and auth ID is cached
-- (cache.luau); opening the block shows it and r rescans the project and
-- runs again. Without a cache the block runs at once, unless it was opened
-- from a bare link (`held`): then nothing runs before Enter.

local Cache = require("./cache")
local Classify = require("../account/classify")
local Cli = require("./cli")
local CliSlot = require("../sdf/cli_slot")
local Compare = require("./compare")
local Config = require("../config")
local Listing = require("../sdf/listing")
local Manageauth = require("../account/manageauth")
local Project = require("../sdf/project")
local Resolve = require("../account/resolve")
local Scope = require("./scope")
local Scratch = require("./scratch")

type Config = Config.Config
type Project = Project.Project
type Entry = Compare.Entry
type Result = Cache.Result

export type Kind = Compare.Kind
export type Filter = "all" | Compare.Status

export type Step = "objects" | "files" | "list" | "info" | "auths"

export type Choice = {
	authId: string,
	-- "project" (project.json), "config" or "cli".
	source: string,
	target: Resolve.Resolution,
	-- From `--list`: "Administrator @ Example Corp".
	detail: string?,
}

export type Picker = {
	loading: boolean,
	error: string?,
	-- Rows of `account:manageauth --list`.
	listed: { Manageauth.Entry },
	selected: number,
}

export type Run = {
	n: number,
	status: "preparing" | "running" | "done" | "cancelled" | "failed",
	dir: string?,
	-- Entries compared / to compare (objects and files), for progress.
	done: number,
	total: number,
	-- What the command in flight does.
	doing: string?,
	error: string?,
	-- Steps of this run (a list-only run after turning account-only on).
	objects: boolean,
	files: boolean,
	list: boolean,
}

export type Message = { tone: string, text: string }

export type State = {
	gen: number,
	cwd: string?,
	held: boolean,
	-- Why it waits: opened from a link, or a production target was picked.
	heldFor: "link" | "target",
	-- tern.now() of the latest message (the account cache's clock) and
	-- os.time() (result times).
	now: number,
	clock: number,
	config: Config?,
	phase: "finding" | "noproject" | "scanning" | "ready",
	root: string?,
	project: Project?,
	texts: Scratch.Texts,
	scanError: string?,
	-- The project root with symlinks resolved (macOS /tmp is /private/tmp):
	-- one cache per project however its directory was reached.
	cacheRoot: string?,
	-- A run waits for the rescan in progress.
	rescan: boolean,
	-- The target; `chosen` when the picker set it.
	authId: string?,
	chosen: boolean,
	target: Resolve.Resolution?,
	cache: Resolve.Cache,
	infoLoading: boolean,
	result: Result?,
	-- `result` came from the cache file, not a run of this block.
	cached: boolean,
	-- The cache file was read for this generation.
	loaded: boolean,
	run: Run?,
	runSeq: number,
	-- The result a running full run replaces; cancel brings it back.
	previous: Result?,
	previousCached: boolean,
	accountOnly: boolean,
	view: "list" | "diff" | "pick",
	kind: Kind,
	filter: Filter,
	selected: number,
	picker: Picker?,
	-- Account commands waiting for the one in flight.
	queue: { Effect },
	inflight: number,
	message: Message?,
}

export type Effect = {
	t: "config" | "find" | "scan" | "load" | "save" | "prepare" | "run" | "cleanup" | "open" | "exit",
	gen: number,
	cwd: string?,
	root: string?,
	-- load/save: file name under Cache.DIR.
	file: string?,
	value: any,
	-- prepare/run: the run number; run/cleanup: the scratch directory.
	run: number?,
	dir: string?,
	plan: Scratch.Plan?,
	step: Step?,
	argv: { string }?,
	timeoutMs: number?,
	-- The auth ID whose CLI slot the command holds.
	slot: string?,
	-- Absolute paths the host reads (at most READ_BYTES each) after the
	-- command and returns in `texts`.
	reads: { string }?,
	-- What the command does, for progress.
	label: string?,
	path: string?,
}

export type Msg =
	{ t: "config", config: Config, now: number?, clock: number? }
	| { t: "found", gen: number, root: string? }
	| {
		t: "scanned",
		gen: number,
		project: Project?,
		texts: Scratch.Texts?,
		realRoot: string?,
		error: string?,
	}
	| { t: "loaded", gen: number, file: string, value: any }
	| { t: "prepared", gen: number, run: number, dir: string?, error: string? }
	| {
		t: "ran",
		gen: number,
		run: number?,
		dir: string?,
		step: Step,
		-- The effect's argv, which names the batch.
		argv: { string }?,
		status: number,
		stdout: string,
		stderr: string,
		timedOut: boolean,
		-- Contents of the effect's `reads` that exist.
		texts: { [string]: string }?,
		now: number,
		clock: number?,
	}
	| { t: "key", name: string, text: string?, shift: boolean? }
	| { t: "action", act: string, value: string? }

local M = {}

M.INFO_TIMEOUT_MS = 60000
M.PAGE = 10
M.READ_BYTES = Compare.MAX_FILE_BYTES + 1
local FILTERS: { Filter } = { "all", "changed", "missing", "account", "error", "identical", "pending" }
M.FILTERS = FILTERS

local function program(s: State): string
	local cfg = s.config
	return if cfg then cfg.suitecloud.program else "suitecloud"
end

local function timeoutMs(s: State): number
	local cfg = s.config
	return if cfg then cfg.suitecloud.timeout_ms else 600000
end

export type InitArgs = {
	cwd: string?,
	held: boolean?,
	heldFor: string?,
	accountOnly: boolean?,
	authId: string?,
}

function M.init(args: InitArgs): (State, { Effect })
	local s: State = {
		gen = 1,
		cwd = args.cwd,
		held = args.held == true,
		heldFor = if args.heldFor == "target" then "target" else "link",
		now = 0,
		clock = 0,
		config = nil,
		phase = "finding",
		root = nil,
		project = nil,
		texts = {},
		scanError = nil,
		cacheRoot = nil,
		rescan = false,
		authId = args.authId,
		chosen = args.authId ~= nil,
		target = nil,
		cache = {},
		infoLoading = false,
		result = nil,
		cached = false,
		loaded = false,
		run = nil,
		runSeq = 0,
		previous = nil,
		previousCached = false,
		accountOnly = args.accountOnly == true,
		view = "list",
		kind = "object",
		filter = "all",
		selected = 1,
		picker = nil,
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

-- Entries of one tab in project order, account-only objects last.
function M.entries(s: State, kind: Kind): { Entry }
	local r = s.result
	if r == nil then
		return {}
	end
	if kind == "file" then
		return r.files
	end
	local only = r.accountOnly
	if not s.accountOnly or only == nil then
		return r.objects
	end
	local out = table.clone(r.objects)
	table.move(only, 1, #only, #out + 1, out)
	return out
end

function M.visible(s: State): { Entry }
	local all = M.entries(s, s.kind)
	if s.filter == "all" then
		return all
	end
	local out: { Entry } = {}
	for _, e in all do
		if e.status == s.filter then
			table.insert(out, e)
		end
	end
	return out
end

function M.counts(entries: { Entry }): { [string]: number }
	local c: { [string]: number } = {}
	for _, f in FILTERS do
		c[f] = 0
	end
	c.all = #entries
	for _, e in entries do
		c[e.status] += 1
	end
	return c
end

function M.selectedEntry(s: State): Entry?
	return M.visible(s)[s.selected]
end

function M.busy(s: State): boolean
	local r = s.run
	return r ~= nil and (r.status == "preparing" or r.status == "running")
end

local busy = M.busy

local function clamp(s: State)
	s.selected = math.clamp(s.selected, 1, math.max(#M.visible(s), 1))
end

local function resolveTarget(s: State)
	local cfg, authId = s.config, s.authId
	s.target = if cfg and authId then Resolve.resolve(authId, { config = cfg, cache = s.cache, now = s.now }) else nil
end

local function abs(root: string, rel: string): string
	return root .. "/" .. rel
end

local function cleanup(s: State, dir: string?, effects: { Effect })
	if dir then
		table.insert(effects, { t = "cleanup", gen = s.gen, dir = dir })
	end
end

local function setRun(s: State, change: (Run) -> ())
	local r = s.run
	if r then
		local run = table.clone(r)
		change(run)
		s.run = run
	end
end

-- One account command at a time, any generation (see cli_slot.luau).
local function pump(s: State, effects: { Effect })
	if s.inflight > 0 or #s.queue == 0 then
		return
	end
	local queue = table.clone(s.queue)
	local nextRun = table.remove(queue, 1) :: Effect
	s.queue = queue
	s.inflight += 1
	setRun(s, function(run)
		run.doing = nextRun.label
	end)
	table.insert(effects, nextRun)
end

local function lookupInfo(s: State, effects: { Effect })
	local cfg, authId, root = s.config, s.authId, s.root
	if cfg == nil or authId == nil or root == nil or s.infoLoading then
		return
	end
	if Resolve.needsLookup(authId, { config = cfg, cache = s.cache, now = s.now }) then
		s.infoLoading = true
		table.insert(effects, {
			t = "run",
			gen = s.gen,
			step = "info",
			argv = { program(s), "account:manageauth", "--info", authId },
			cwd = root,
			timeoutMs = M.INFO_TIMEOUT_MS,
		})
	end
end

local function appId(project: Project): string?
	local m = project.manifest
	if m and m.projectType == "SUITEAPP" and m.publisherId and m.projectId then
		return m.publisherId .. "." .. m.projectId
	end
	return nil
end

local function objectProblem(s: State, o: Project.SdfObject): string?
	if not string.find(o.type, "^%a[%w_]*$") then
		return "the object type <" .. o.type .. "> cannot be imported"
	end
	if s.texts[o.path] == nil then
		return "the project copy could not be read"
	end
	return Cli.unsafeScriptId(o.scriptId)
end

-- Pending entries for every project object and file, and run-level notes.
local function pendingResult(s: State, project: Project, authId: string): Result
	local objects: { Entry } = {}
	for _, o in project.objects do
		local e = Compare.pending("object", o.scriptId, o.type, o.path)
		local why = objectProblem(s, o)
		table.insert(objects, if why then Compare.failed(e, why) else e)
	end
	local problems: { string } = {}
	local files: { Entry } = {}
	local manifest = project.manifest
	if manifest and manifest.projectType == "SUITEAPP" then
		if #project.files > 0 then
			table.insert(problems, "File Cabinet files were not compared: file:import refuses SuiteApp projects")
		end
	else
		for _, f in project.files do
			local e = Compare.pending("file", f.fileCabinetPath, nil, f.path)
			local why = Cli.unsafePath(f.fileCabinetPath)
			table.insert(files, if why then Compare.failed(e, why) else e)
		end
	end
	if project.truncated then
		table.insert(problems, "the project scan stopped at projects.max_files: some files were not compared")
	end
	local skipped = 0
	local objectsDir = project.projectFolder .. "/Objects/"
	for _, d in project.diagnostics do
		local p = d.path
		if
			(d.code == "xml-parse" or d.code == "object-scriptid")
			and p
			and string.sub(p, 1, #objectsDir) == objectsDir
		then
			skipped += 1
		end
	end
	if skipped > 0 then
		table.insert(
			problems,
			string.format(
				"%d object file%s could not be read as an object and %s skipped",
				skipped,
				if skipped == 1 then "" else "s",
				if skipped == 1 then "was" else "were"
			)
		)
	end
	local t = s.target
	return {
		root = s.cacheRoot or project.root,
		authId = authId,
		account = if t and t.source ~= "unknown" then t.accountId or t.label else nil,
		production = if t then t.production else true,
		at = 0,
		objects = objects,
		files = files,
		accountOnly = nil,
		problems = problems,
	}
end

local function pendingCount(entries: { Entry }): number
	local n = 0
	for _, e in entries do
		if e.status == "pending" then
			n += 1
		end
	end
	return n
end

local function listEffect(s: State, r: Run): Effect
	local project = s.project :: Project
	return {
		t = "run",
		gen = s.gen,
		run = r.n,
		dir = r.dir,
		step = "list",
		argv = Cli.listArgv(program(s), appId(project)),
		cwd = r.dir,
		timeoutMs = timeoutMs(s),
		slot = s.authId,
		reads = {},
		label = "object:list",
	}
end

-- Queues the account commands of a prepared run.
local function enqueue(s: State, effects: { Effect })
	local project, r, result, authId = s.project, s.run, s.result, s.authId
	if project == nil or r == nil or result == nil or authId == nil or r.dir == nil then
		return
	end
	local dir = r.dir :: string
	local pf = project.projectFolder
	local queue: { Effect } = {}
	local function push(step: Step, argv: { string }, reads: { string }, label: string)
		table.insert(queue, {
			t = "run",
			gen = s.gen,
			run = r.n,
			dir = dir,
			step = step,
			argv = argv,
			cwd = dir,
			timeoutMs = timeoutMs(s),
			slot = authId,
			reads = reads,
			label = label,
		})
	end
	if r.objects then
		local refs: { Cli.ObjectRef } = {}
		for _, e in result.objects do
			if e.status == "pending" then
				table.insert(refs, { type = e.type :: string, scriptId = e.id })
			end
		end
		for _, b in Cli.objectBatches(refs) do
			local reads: { string } = {}
			for _, sid in b.scriptIds do
				table.insert(reads, abs(dir, Scratch.objectPath(pf, sid)))
			end
			local label = string.format("object:import %s (%d)", b.type, #b.scriptIds)
			push("objects", Cli.objectArgv(program(s), b, appId(project)), reads, label)
		end
	end
	if r.files then
		local paths: { string } = {}
		local byPath: { [string]: string } = {}
		for _, e in result.files do
			if e.status == "pending" then
				table.insert(paths, e.id)
				byPath[e.id] = e.localPath :: string
			end
		end
		for _, batch in Cli.fileBatches(paths) do
			local reads: { string } = {}
			for _, p in batch do
				table.insert(reads, abs(dir, Scratch.filePath(pf, p)))
				table.insert(reads, abs(project.root, byPath[p]))
			end
			push("files", Cli.fileArgv(program(s), batch), reads, string.format("file:import (%d)", #batch))
		end
	end
	if r.list then
		table.insert(queue, listEffect(s, r))
	end
	s.queue = queue
	pump(s, effects)
end

-- Starts a run over everything (`full`) or only the account-only listing.
local function startRun(s: State, full: boolean, effects: { Effect })
	local project, authId = s.project, s.authId
	if project == nil or authId == nil or s.phase ~= "ready" or s.config == nil or busy(s) then
		return
	end
	local plan, why = Scratch.plan(s.texts, project.projectFolder, authId)
	if plan == nil then
		s.message = { tone = "error", text = "Cannot compare: " .. (why or "?") }
		return
	end
	s.held = false
	s.runSeq += 1
	local result: Result
	if full or s.result == nil then
		local before = s.result
		s.previous = if before and before.at > 0 then before else nil
		s.previousCached = s.cached
		result = pendingResult(s, project, authId)
		full = true
	else
		result = s.result :: Result
	end
	s.result = result
	s.cached = false
	s.run = {
		n = s.runSeq,
		status = "preparing",
		dir = nil,
		done = 0,
		total = pendingCount(result.objects) + pendingCount(result.files),
		doing = "preparing the scratch project",
		error = nil,
		objects = full,
		files = full,
		list = s.accountOnly,
	}
	s.message = nil
	clamp(s)
	table.insert(effects, { t = "prepare", gen = s.gen, run = s.runSeq, plan = plan })
end

-- A rescan of the project, then a full run (r, Enter on a held block).
local function rerun(s: State, effects: { Effect })
	if busy(s) then
		s.message = { tone = "muted", text = "A comparison is running; c cancels it" }
		return
	end
	if s.root == nil or s.phase ~= "ready" then
		return
	end
	s.held = false
	s.rescan = true
	s.phase = "scanning"
	table.insert(effects, { t = "scan", gen = s.gen, root = s.root })
end

local function finish(s: State, effects: { Effect })
	local r = s.run
	if r == nil or r.status ~= "running" or s.inflight > 0 or #s.queue > 0 then
		return
	end
	setRun(s, function(run)
		run.status = "done"
		run.doing = nil
	end)
	s.previous = nil
	local result = table.clone(s.result :: Result)
	if r.objects or result.at == 0 then
		result.at = s.clock
	end
	s.result = result
	cleanup(s, r.dir, effects)
	table.insert(effects, {
		t = "save",
		gen = s.gen,
		file = Cache.fileName(result.root, result.authId),
		value = Cache.encode(result),
	})
end

local function setEntries(s: State, kind: Kind, list: { Entry })
	local result = table.clone(s.result :: Result)
	if kind == "object" then
		result.objects = list
	else
		result.files = list
	end
	s.result = result
end

-- Marks what a run left pending as not compared, with why.
local function abandon(s: State, why: string)
	local result = s.result
	if result == nil then
		return
	end
	local function mark(list: { Entry }): { Entry }
		local out: { Entry } = table.create(#list)
		for i, e in list do
			out[i] = if e.status == "pending" then Compare.failed(e, why) else e
		end
		return out
	end
	setEntries(s, "object", mark(result.objects))
	setEntries(s, "file", mark(result.files))
end

local function fail(s: State, why: string, effects: { Effect })
	local dir = if s.run then (s.run :: Run).dir else nil
	setRun(s, function(run)
		run.status = "failed"
		run.error = why
		run.doing = nil
	end)
	s.queue = {}
	abandon(s, "not compared: " .. why)
	if s.inflight == 0 then
		cleanup(s, dir, effects)
	end
end

-- Answers after which the next command would fail the same way.
local function fatal(msg: any): boolean
	return msg.timedOut
		or msg.status == CliSlot.BUSY_STATUS
		or string.find(msg.stdout .. msg.stderr, Cli.REAUTH_MARKER, 1, true) ~= nil
end

local function failure(s: State, msg: any): string
	return Cli.failure(msg.status, msg.stdout, msg.stderr, msg.timedOut, timeoutMs(s), s.authId or "?")
end

-- The script ids or paths an import command named.
local function batchOf(argv: { string }?): { [string]: boolean }
	local out: { [string]: boolean } = {}
	local on = false
	local list: { string } = argv or {}
	for _, a in list do
		if a == "--scriptid" or a == "--paths" then
			on = true
		elseif string.sub(a, 1, 2) == "--" then
			on = false
		elseif on then
			out[a] = true
		end
	end
	return out
end

local function onObjects(s: State, msg: any): number
	local project = s.project :: Project
	local dir = (s.run :: Run).dir :: string
	local parsed = Cli.parseObjectImport(msg.stdout, msg.stderr)
	local why = if parsed.recognized then nil else failure(s, msg)
	local texts: { [string]: string } = msg.texts or {}
	local batch = batchOf(msg.argv)
	local result = s.result :: Result
	local out: { Entry } = table.create(#result.objects)
	local n = 0
	for i, e in result.objects do
		if e.status ~= "pending" or not batch[e.id] then
			out[i] = e
			continue
		end
		n += 1
		local copy = texts[abs(dir, Scratch.objectPath(project.projectFolder, e.id))]
		local mine = s.texts[e.localPath :: string]
		local failed = parsed.failed[e.id]
		if copy ~= nil then
			out[i] = Compare.object(e, mine, copy)
		elseif failed then
			out[i] = if Cli.isMissing(failed) then Compare.missing(e) else Compare.failed(e, failed)
		elseif parsed.imported[e.id] then
			out[i] = Compare.object(e, mine, nil)
		else
			out[i] = Compare.failed(e, why or "the CLI did not report this object")
		end
	end
	setEntries(s, "object", out)
	return n
end

local function onFiles(s: State, msg: any): number
	local project = s.project :: Project
	local dir = (s.run :: Run).dir :: string
	local batch = batchOf(msg.argv)
	local asked: { string } = {}
	for p in batch do
		table.insert(asked, p)
	end
	local parsed = Cli.parseFileImport(msg.stdout, msg.stderr, asked)
	local why = if parsed.recognized then nil else failure(s, msg)
	local texts: { [string]: string } = msg.texts or {}
	local result = s.result :: Result
	local out: { Entry } = table.create(#result.files)
	local n = 0
	for i, e in result.files do
		if e.status ~= "pending" or not batch[e.id] then
			out[i] = e
			continue
		end
		n += 1
		local copy = texts[abs(dir, Scratch.filePath(project.projectFolder, e.id))]
		local mine = texts[abs(project.root, e.localPath :: string)]
		local failed = parsed.failed[e.id]
		if copy ~= nil then
			out[i] = Compare.file(e, mine, copy)
		elseif failed then
			out[i] = if Cli.isMissing(failed) then Compare.missing(e) else Compare.failed(e, failed)
		elseif parsed.imported[e.id] then
			out[i] = Compare.file(e, mine, nil)
		else
			out[i] = Compare.failed(e, why or "the CLI did not report this file")
		end
	end
	setEntries(s, "file", out)
	return n
end

local function onList(s: State, msg: any)
	local project = s.project :: Project
	local result = table.clone(s.result :: Result)
	local parsed = if msg.status == 0 and not msg.timedOut
		then Listing.objects(Listing.split(msg.stdout), msg.status)
		else nil
	if parsed == nil then
		local problems = table.clone(result.problems)
		table.insert(problems, "object:list failed: " .. failure(s, msg))
		result.problems = problems
		s.result = result
		return
	end
	local ids: { string } = {}
	local have: { [string]: boolean } = {}
	for _, o in project.objects do
		table.insert(ids, o.scriptId)
		have[string.lower(o.scriptId)] = true
	end
	local only: { Entry } = {}
	for _, o in Scope.accountOnly(parsed.objects, Scope.prefixes(ids), have) do
		local e = Compare.pending("object", o.scriptId, o.type, nil)
		e.status = "account"
		table.insert(only, e)
	end
	result.accountOnly = only
	s.result = result
end

local function onInfo(s: State, msg: any)
	if msg.gen ~= s.gen then
		return
	end
	s.infoLoading = false
	local authId = s.authId
	if authId == nil then
		return
	end
	local info = if msg.status == 0 then Manageauth.parseInfo(Manageauth.lines(msg.stdout)) else nil
	if info and info.accountId then
		s.cache = Resolve.store(s.cache, Resolve.fromInfo(info, msg.now))
	else
		local why = if msg.timedOut
			then "timed out"
			else Manageauth.errorText(Manageauth.lines(msg.stderr .. "\n" .. msg.stdout))
		s.cache = Resolve.store(s.cache, Resolve.fromError(authId, why or ("exit " .. msg.status), msg.now))
	end
	resolveTarget(s)
end

local function onAuths(s: State, msg: any)
	local p = s.picker
	if p == nil then
		return
	end
	local picker = table.clone(p)
	picker.loading = false
	local entries = if msg.status == 0 then Manageauth.parseList(Manageauth.lines(msg.stdout)) else nil
	if entries then
		picker.listed = entries
	elseif msg.status ~= 0 or msg.timedOut then
		picker.error = if msg.timedOut
			then "account:manageauth --list timed out"
			else Manageauth.errorText(Manageauth.lines(msg.stderr .. "\n" .. msg.stdout))
				or ("account:manageauth --list exited " .. msg.status)
	end
	s.picker = picker
end

local function onRan(s: State, msg: any, effects: { Effect })
	if msg.step == "info" then
		onInfo(s, msg)
		return
	elseif msg.step == "auths" then
		onAuths(s, msg)
		return
	end
	s.inflight = math.max(s.inflight - 1, 0)
	local r = s.run
	if r == nil or msg.gen ~= s.gen or msg.run ~= r.n or r.status ~= "running" then
		-- A cancelled, failed or superseded run: its directory goes once
		-- nothing writes into it.
		if s.inflight == 0 and not (r and r.dir == msg.dir and busy(s)) then
			cleanup(s, msg.dir, effects)
		end
		pump(s, effects)
		return
	end
	local n = 0
	if msg.step == "objects" then
		n = onObjects(s, msg)
	elseif msg.step == "files" then
		n = onFiles(s, msg)
	else
		onList(s, msg)
	end
	setRun(s, function(run)
		run.done += n
		run.doing = nil
	end)
	if fatal(msg) then
		fail(s, failure(s, msg), effects)
		return
	end
	pump(s, effects)
	finish(s, effects)
end

local function cancel(s: State, effects: { Effect })
	local r = s.run
	if r == nil or not busy(s) then
		return
	end
	setRun(s, function(run)
		run.status = "cancelled"
		run.doing = nil
	end)
	s.queue = {}
	s.message = {
		tone = "warning",
		text = (if s.inflight > 0
			then "Cancelled; the command in flight finishes in the background and its answer is ignored"
			else "Cancelled") .. (if s.previous then "; showing the previous result" else ""),
	}
	local before = s.previous
	if before then
		s.result = before
		s.cached = s.previousCached
		s.previous = nil
		clamp(s)
	end
	if s.inflight == 0 then
		cleanup(s, r.dir, effects)
	end
end

-- A new target or project: results and run belong to the old one.
local function retarget(s: State, effects: { Effect })
	cancel(s, effects)
	s.gen += 1
	s.result = nil
	s.previous = nil
	s.cached = false
	s.loaded = false
	s.run = nil
	s.selected = 1
	s.infoLoading = false
	resolveTarget(s)
	local root, authId = s.cacheRoot, s.authId
	if root and authId and s.phase == "ready" then
		table.insert(effects, { t = "load", gen = s.gen, file = Cache.fileName(root, authId) })
		lookupInfo(s, effects)
	end
end

local function onScanned(s: State, msg: any, effects: { Effect })
	local rescan = s.rescan
	s.rescan = false
	if msg.project == nil then
		s.phase = "noproject"
		s.scanError = msg.error or "the project could not be read"
		return
	end
	local project = msg.project :: Project
	s.project = project
	s.texts = msg.texts or {}
	s.cacheRoot = msg.realRoot or project.root
	s.scanError = nil
	s.phase = "ready"
	local authId = if s.chosen then s.authId else project.defaultAuthId
	if rescan and authId == s.authId and s.loaded then
		startRun(s, true, effects)
		return
	end
	s.authId = authId
	if rescan then
		-- project.json now names another auth ID: show its cache, or run.
		s.held = false
	end
	retarget(s, effects)
end

local function onLoaded(s: State, msg: any, effects: { Effect })
	local root, authId = s.cacheRoot, s.authId
	if root == nil or authId == nil or msg.gen ~= s.gen then
		return
	end
	s.loaded = true
	if s.result ~= nil then
		return
	end
	local r = Cache.decode(msg.value, root, authId)
	if r then
		s.result = r
		s.cached = true
		clamp(s)
	elseif not s.held then
		startRun(s, true, effects)
	end
end

-- Auth IDs the picker offers: the project's, configured ones, the CLI's.
function M.choices(s: State): { Choice }
	local out: { Choice } = {}
	local cfg = s.config
	if cfg == nil then
		return out
	end
	local seen: { [string]: boolean } = {}
	local opts = { config = cfg, cache = s.cache, now = s.now }
	local function add(authId: string, source: string, detail: string?, accountId: string?)
		if seen[authId] then
			return
		end
		seen[authId] = true
		local target = Resolve.resolve(authId, opts)
		if target.source == "unknown" and accountId then
			local c = Classify.account(accountId, cfg)
			target = {
				authId = authId,
				source = "cli",
				accountId = c.accountId,
				production = c.production,
				label = c.label,
				problem = nil,
			}
		elseif target.source == "unknown" and source == "cli" then
			-- `--list` names the account domain only for non-production
			-- accounts (lib/account/manageauth.luau).
			target = {
				authId = authId,
				source = "cli",
				accountId = nil,
				production = true,
				label = "PROD",
				problem = "account:manageauth --list shows no account domain, which it omits for production accounts",
			}
		end
		table.insert(out, { authId = authId, source = source, target = target, detail = detail })
	end
	local project = s.project
	if project and project.defaultAuthId then
		add(project.defaultAuthId, "project", nil, nil)
	end
	for _, a in cfg.accounts do
		for _, id in a.auth_ids do
			add(id, "config", nil, nil)
		end
	end
	local p = s.picker
	if p then
		for _, e in p.listed do
			local detail = if e.role and e.accountName
				then e.role .. " @ " .. e.accountName
				else e.role or e.accountName
			add(e.authId, "cli", detail, e.accountId)
		end
	end
	return out
end

local function openPicker(s: State, effects: { Effect })
	if s.phase ~= "ready" or s.root == nil then
		return
	end
	s.view = "pick"
	local at = 1
	for i, c in M.choices(s) do
		if c.authId == s.authId then
			at = i
		end
	end
	local p = s.picker
	if p == nil or p.error then
		s.picker = { loading = true, error = nil, listed = if p then p.listed else {}, selected = at }
		table.insert(effects, {
			t = "run",
			gen = s.gen,
			step = "auths",
			argv = { program(s), "account:manageauth", "--list" },
			cwd = s.root,
			timeoutMs = M.INFO_TIMEOUT_MS,
		})
	else
		local picker = table.clone(p)
		picker.selected = at
		s.picker = picker
	end
end

local function pick(s: State, i: number, effects: { Effect })
	local c = M.choices(s)[i]
	if c == nil then
		return
	end
	s.view = "list"
	if c.authId == s.authId then
		return
	end
	s.authId = c.authId
	s.chosen = true
	-- What the CLI list showed holds until --info answers.
	if c.target.source == "cli" and c.target.accountId then
		s.cache = Resolve.store(
			s.cache,
			{ authId = c.authId, accountId = c.target.accountId, at = s.now, error = nil, errorAt = nil }
		)
	end
	-- Picking an account is not running against it: production (and
	-- unknown) targets wait for Enter.
	if c.target.production then
		s.held = true
		s.heldFor = "target"
	end
	retarget(s, effects)
end

local function move(s: State, delta: number)
	if s.view == "pick" then
		local p = s.picker
		if p then
			local picker = table.clone(p)
			picker.selected = math.clamp(p.selected + delta, 1, math.max(#M.choices(s), 1))
			s.picker = picker
		end
		return
	end
	s.selected += delta
	clamp(s)
end

-- The next (dir 1) or previous changed entry.
local function jump(s: State, dir: number)
	local list = M.visible(s)
	local i = s.selected + dir
	while i >= 1 and i <= #list do
		if list[i].status == "changed" then
			s.selected = i
			return
		end
		i += dir
	end
end

local function setFilter(s: State, f: Filter)
	s.filter = f
	s.selected = 1
end

local function toggleAccountOnly(s: State, effects: { Effect })
	s.accountOnly = not s.accountOnly
	clamp(s)
	if not s.accountOnly then
		return
	end
	local r = s.run
	if r and busy(s) then
		if not r.list then
			setRun(s, function(run)
				run.list = true
			end)
			if r.status == "running" then
				local queue = table.clone(s.queue)
				table.insert(queue, listEffect(s, s.run :: Run))
				s.queue = queue
				pump(s, effects)
			end
		end
		return
	end
	local result = s.result
	if result and result.accountOnly == nil and not s.held then
		startRun(s, false, effects)
	end
end

local function upper(msg: any, letter: string): boolean
	return msg.name == string.upper(letter) or (msg.name == letter and msg.shift == true)
end

local function lower(msg: any, letter: string): boolean
	return msg.name == letter and not msg.shift
end

local function isEnter(msg: any): boolean
	return msg.name == "enter" or msg.name == "return"
end

local function openDetail(s: State)
	local e = M.selectedEntry(s)
	if e and (e.diff or e.note) then
		s.view = "diff"
	end
end

local function pickKey(s: State, msg: any, effects: { Effect }): boolean
	local name = msg.name
	if isEnter(msg) then
		local p = s.picker
		if p then
			pick(s, p.selected, effects)
		end
	elseif name == "escape" or lower(msg, "q") or lower(msg, "p") then
		s.view = "list"
	elseif name == "down" or lower(msg, "j") then
		move(s, 1)
	elseif name == "up" or lower(msg, "k") then
		move(s, -1)
	else
		return false
	end
	return true
end

local function diffKey(s: State, msg: any): boolean
	local name = msg.name
	if name == "escape" or lower(msg, "q") or isEnter(msg) then
		s.view = "list"
	elseif lower(msg, "n") then
		jump(s, 1)
	elseif upper(msg, "n") then
		jump(s, -1)
	elseif name == "down" or lower(msg, "j") then
		move(s, 1)
	elseif name == "up" or lower(msg, "k") then
		move(s, -1)
	else
		return false
	end
	return true
end

local function key(s: State, msg: any, effects: { Effect }): boolean
	if s.view == "pick" then
		return pickKey(s, msg, effects)
	elseif s.view == "diff" then
		return diffKey(s, msg)
	end
	local name = msg.name
	if (s.held and isEnter(msg)) or lower(msg, "r") then
		rerun(s, effects)
	elseif name == "escape" then
		if busy(s) then
			cancel(s, effects)
		else
			table.insert(effects, { t = "exit", gen = s.gen })
		end
	elseif lower(msg, "q") then
		table.insert(effects, { t = "exit", gen = s.gen })
	elseif lower(msg, "c") then
		cancel(s, effects)
	elseif lower(msg, "p") then
		openPicker(s, effects)
	elseif lower(msg, "o") then
		toggleAccountOnly(s, effects)
	elseif name == "tab" then
		s.kind = if s.kind == "object" then "file" else "object"
		s.selected = 1
	elseif lower(msg, "s") then
		local i = table.find(FILTERS, s.filter) or 1
		setFilter(s, FILTERS[i % #FILTERS + 1])
	elseif upper(msg, "s") then
		local i = table.find(FILTERS, s.filter) or 1
		setFilter(s, FILTERS[(i - 2) % #FILTERS + 1])
	elseif name == "down" or lower(msg, "j") then
		move(s, 1)
	elseif name == "up" or lower(msg, "k") then
		move(s, -1)
	elseif name == "page_down" then
		move(s, M.PAGE)
	elseif name == "page_up" then
		move(s, -M.PAGE)
	elseif name == "home" or lower(msg, "g") then
		s.selected = 1
	elseif name == "end" or upper(msg, "g") then
		s.selected = math.max(#M.visible(s), 1)
	elseif lower(msg, "n") then
		jump(s, 1)
	elseif upper(msg, "n") then
		jump(s, -1)
	elseif isEnter(msg) then
		openDetail(s)
	elseif lower(msg, "e") then
		local e = M.selectedEntry(s)
		if e and e.localPath and s.root then
			table.insert(effects, { t = "open", gen = s.gen, path = abs(s.root :: string, e.localPath :: string) })
		end
	else
		return false
	end
	return true
end

local function action(s: State, msg: any, effects: { Effect })
	local act, value = msg.act, msg.value or ""
	local i = tonumber(value)
	if act == "kind" and (value == "object" or value == "file") then
		s.kind = value
		s.selected = 1
	elseif act == "filter" and table.find(FILTERS, value) then
		setFilter(s, value :: Filter)
	elseif act == "sel" and i then
		s.selected = math.floor(i)
		clamp(s)
	elseif act == "open" and i then
		s.selected = math.floor(i)
		clamp(s)
		openDetail(s)
	elseif act == "back" then
		s.view = "list"
	elseif act == "pick" and i then
		pick(s, math.floor(i), effects)
	elseif act == "picker" then
		openPicker(s, effects)
	elseif act == "run" then
		rerun(s, effects)
	elseif act == "cancel" then
		cancel(s, effects)
	elseif act == "accountonly" then
		toggleAccountOnly(s, effects)
	end
end

function M.update(prev: State, msg: Msg): (State, { Effect })
	local s = table.clone(prev)
	local effects: { Effect } = {}
	local m: any = msg
	if type(m.now) == "number" then
		s.now = m.now
	end
	if type(m.clock) == "number" then
		s.clock = m.clock
	end
	if m.t == "config" then
		s.config = m.config
		resolveTarget(s)
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
		onScanned(s, m, effects)
	elseif m.t == "loaded" then
		onLoaded(s, m, effects)
	elseif m.t == "prepared" then
		local r = s.run
		if r == nil or m.gen ~= s.gen or m.run ~= r.n or r.status ~= "preparing" then
			cleanup(s, m.dir, effects)
		elseif m.dir == nil then
			setRun(s, function(run)
				run.status = "failed"
				run.error = "the scratch project could not be created: " .. (m.error or "?")
				run.doing = nil
			end)
			abandon(s, "not compared: the scratch project could not be created")
		else
			setRun(s, function(run)
				run.status = "running"
				run.dir = m.dir
				run.doing = nil
			end)
			enqueue(s, effects)
			finish(s, effects)
		end
	elseif m.t == "ran" then
		onRan(s, m, effects)
	elseif m.t == "key" then
		if not key(s, m, effects) then
			return prev, {}
		end
	elseif m.t == "action" then
		action(s, m, effects)
	end
	return s, effects
end

-- What `save` persists: the directory, whether it still waits for Enter,
-- a chosen target and the account-only toggle.
function M.saved(s: State): { cwd: string?, held: boolean, heldFor: string, authId: string?, accountOnly: boolean }
	return {
		cwd = s.cwd,
		held = s.held,
		heldFor = s.heldFor,
		authId = if s.chosen then s.authId else nil,
		accountOnly = s.accountOnly,
	}
end

-- The scratch directory a command may still write into, or nil.
function M.liveDir(s: State): string?
	local r = s.run
	return if r and s.inflight > 0 then r.dir else nil
end

-- The scratch directory of an unfinished run nothing writes into anymore.
function M.idleDir(s: State): string?
	local r = s.run
	return if r and s.inflight == 0 and (r.status == "preparing" or r.status == "running") then r.dir else nil
end

return M
