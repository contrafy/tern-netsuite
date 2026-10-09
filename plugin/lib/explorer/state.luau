--!strict
-- SDF project explorer (block `explorer`): Elm-style core. The adapter
-- (plugin/explorer_host.luau) runs the effects returned here (config load,
-- locating the repository, finding and scanning projects, `manageauth
-- --info` lookups, opening files, copying, upload requests) and feeds the
-- answers back as messages. Every async answer carries the generation of
-- the scan that asked for it; a rescan bumps it so late answers are dropped.

local Checks = require("../sdf/checks")
local Project = require("../sdf/project")
local Resolve = require("../account/resolve")
local Rows = require("./rows")
local Symlinks = require("../sdf/symlinks")
local Types = require("./types")
local Upload = require("./upload")

export type State = Types.State
export type Msg = Types.Msg
export type Effect = Types.Effect
export type Row = Types.Row

type Key = Types.Key

local M = {}

-- Projects scanned per run; a monorepo has tens.
M.MAX_PROJECTS = 200
M.DEFAULT_HEIGHT = 40
M.DEFAULT_WIDTH = 100
-- Characters of the dock's key hints (render.luau), for the line budget.
M.HINTS_CHARS = 115
M.MIN_ROWS = 5
-- Lines drawn at most, whatever the pane height.
M.MAX_RENDER_ROWS = 200

M.PICK_FLAG = "--pick"

export type InitOpts = { cwd: string?, height: number?, width: number? }

local function absolute(p: string?): string?
	if p and string.sub(p, 1, 1) == "/" then
		return Symlinks.normalize(p)
	end
	return nil
end

local function dirname(path: string): string
	local d = string.match(path, "^(.*)/[^/]*$")
	return if d == nil or d == "" then "/" else d
end

function M.init(args: { string }, opts: InitOpts): (State, { Effect })
	local cwd: string? = nil
	local pickPath: string? = nil
	local i = 1
	while i <= #args do
		local a = args[i]
		if a == M.PICK_FLAG then
			pickPath = absolute(args[i + 1])
			i += 2
		else
			cwd = cwd or absolute(a)
			i += 1
		end
	end
	cwd = cwd or absolute(opts.cwd) or (if pickPath then dirname(pickPath) else nil) or "/"
	local s: State = {
		gen = 1,
		cwd = cwd :: string,
		pickPath = pickPath,
		config = nil,
		now = 0,
		cache = {},
		inflight = {},
		phase = "loading",
		base = nil,
		repoRoot = nil,
		projectRoot = nil,
		queue = {},
		total = 0,
		done = 0,
		current = nil,
		skipped = 0,
		pending = {},
		pendingErrors = {},
		problem = nil,
		projects = {},
		errors = {},
		findings = {},
		index = nil,
		scanned = false,
		tab = "projects",
		detail = nil,
		picking = pickPath ~= nil,
		pick = nil,
		sel = {},
		offset = {},
		filters = {},
		editing = false,
		height = opts.height or M.DEFAULT_HEIGHT,
		width = opts.width or M.DEFAULT_WIDTH,
		notice = nil,
	}
	return s, { { t = "config", gen = s.gen } }
end

function M.viewKey(s: State): string
	return Rows.viewKey(s)
end

function M.rows(s: State): { Row }
	return Rows.build(s)
end

function M.progress(s: State): { done: number, total: number, current: string? }
	return { done = s.done, total = s.total, current = s.current }
end

-- Lines left for rows: the pane height minus what the header, tabs,
-- progress, notice, filter, overflow lines, the gaps between them and the
-- dock take at this width.
function M.viewport(s: State): number
	local w = s.width
	-- Header, gap, tabs, gap.
	local chrome = Rows.wrap("SDF explorer  " .. (s.base or s.cwd), w) + 3
	if s.phase ~= "ready" then
		chrome += 2
	end
	if s.skipped > 0 then
		chrome += 2
	end
	if s.notice then
		chrome += Rows.wrap(s.notice.text, w) + 1
	end
	if s.editing or s.filters[M.viewKey(s)] then
		chrome += 2
	end
	-- Overflow lines above and below, the gaps around the rows, the dock.
	chrome += 5 + Rows.wrap(string.rep("x ", M.HINTS_CHARS // 2), w)
	return math.clamp(s.height - chrome, M.MIN_ROWS, M.MAX_RENDER_ROWS)
end

-- First and last row index to draw, keeping `selected` in view.
function M.window(s: State, rows: { Row }, selected: number): (number, number)
	return Rows.window(rows, math.max(selected, 1), s.offset[M.viewKey(s)], M.viewport(s), s.width)
end

-- Index of the selected row in `rows` (the first selectable one when the
-- remembered key is gone), or 0 when nothing is selectable.
function M.selectedIndex(s: State, rows: { Row }): number
	local want = s.sel[M.viewKey(s)]
	local first = 0
	for i, r in rows do
		if r.target then
			if r.key == want then
				return i
			end
			if first == 0 then
				first = i
			end
		end
	end
	return first
end

function M.selected(s: State): Row?
	local rows = M.rows(s)
	local i = M.selectedIndex(s, rows)
	return if i > 0 then rows[i] else nil
end

-- djb2 of a row key: a click names the row index it was rendered at and
-- this hash, so a click on a list that changed since does nothing.
local function hash(key: string): string
	local h = 5381
	for i = 1, #key do
		h = (h * 33 + string.byte(key, i)) % 4294967296
	end
	return string.format("%08x", h)
end

function M.clickValue(rows: { Row }, index: number): string
	return index .. ":" .. hash(rows[index].key)
end

local function keepVisible(s: State, rows: { Row }, index: number)
	local first = M.window(s, rows, index)
	s.offset[M.viewKey(s)] = first
end

local function selectIndex(s: State, rows: { Row }, index: number)
	local r = rows[index]
	if r then
		s.sel[M.viewKey(s)] = r.key
		keepVisible(s, rows, index)
	end
end

-- Moves the selection `delta` selectable rows (clamped), or to the first
-- (`to` = 1) / last (`to` = -1) selectable row.
local function move(s: State, delta: number, to: number?)
	local rows = M.rows(s)
	local selectable: { number } = {}
	local pos = 0
	local current = M.selectedIndex(s, rows)
	for i, r in rows do
		if r.target then
			table.insert(selectable, i)
			if i == current then
				pos = #selectable
			end
		end
	end
	if #selectable == 0 then
		return
	end
	local nextPos = if to == 1 then 1 elseif to == -1 then #selectable else math.clamp(pos + delta, 1, #selectable)
	selectIndex(s, rows, selectable[nextPos])
end

local function setNotice(s: State, text: string, tone: string)
	s.notice = { text = text, tone = tone }
end

-- Scanning --------------------------------------------------------------------

local function startScan(s: State, effects: { Effect })
	s.gen += 1
	s.phase = "loading"
	s.queue = {}
	s.total = 0
	s.done = 0
	s.current = nil
	s.skipped = 0
	s.pending = {}
	s.pendingErrors = {}
	s.problem = nil
	table.insert(effects, { t = "config", gen = s.gen })
end

local function nextScan(s: State, effects: { Effect })
	local root = table.remove(s.queue, 1)
	if root then
		s.current = root
		table.insert(effects, { t = "scan", gen = s.gen, root = root })
	end
end

local function lookups(s: State, effects: { Effect })
	local opts = Rows.resolveOpts(s)
	if opts == nil then
		return
	end
	local seen: { [string]: boolean } = {}
	for _, p in s.projects do
		local id = p.defaultAuthId
		if id and not seen[id] then
			seen[id] = true
			if not s.inflight[id] and Resolve.needsLookup(id, opts) then
				s.inflight[id] = true
				table.insert(effects, { t = "lookup", authId = id })
			end
		end
	end
end

local function buildPick(s: State)
	local path = s.pickPath
	if path == nil or s.index == nil then
		return
	end
	local owners = Symlinks.owners(s.index :: Symlinks.Index, path)
	local objects = 0
	for _, o in owners do
		if o.fileCabinetPath == nil then
			objects += 1
		end
	end
	s.pick = { path = path, decision = Upload.decide(owners), objects = objects }
end

local function finishScan(s: State, effects: { Effect })
	local projects = s.pending
	table.sort(projects, function(a: Types.Project, b: Types.Project): boolean
		if a.name ~= b.name then
			return a.name < b.name
		end
		return a.root < b.root
	end)
	s.projects = projects
	s.errors = s.pendingErrors
	s.pending = {}
	s.pendingErrors = {}
	s.findings = Checks.run(projects)
	s.index = Symlinks.index(projects)
	s.phase = "ready"
	s.scanned = true
	s.current = nil
	if s.detail and Rows.project(s, s.detail) == nil then
		s.detail = nil
	end
	buildPick(s)
	lookups(s, effects)
end

local function onDiscovered(s: State, roots: { string }, err: string?, effects: { Effect })
	local list: { string } = {}
	local seen: { [string]: boolean } = {}
	local function add(r: string)
		local n = Symlinks.normalize(r)
		if not seen[n] then
			seen[n] = true
			table.insert(list, n)
		end
	end
	for _, r in roots do
		add(r)
	end
	if s.projectRoot then
		add(s.projectRoot)
	end
	table.sort(list)
	if #list > M.MAX_PROJECTS then
		s.skipped = #list - M.MAX_PROJECTS
		list = table.move(list, 1, M.MAX_PROJECTS, 1, table.create(M.MAX_PROJECTS))
	end
	s.problem = err
	s.queue = list
	s.total = #list
	s.done = 0
	if #list == 0 then
		finishScan(s, effects)
		return
	end
	s.phase = "scanning"
	nextScan(s, effects)
end

-- Actions -----------------------------------------------------------------------

local function grantFor(s: State, owner: Types.Owner): Effect?
	local fc = owner.fileCabinetPath
	if fc == nil then
		return nil
	end
	local p = Rows.project(s, owner.root)
	local authId = if p then p.defaultAuthId else nil
	local target = Rows.target(s, authId)
	return {
		t = "upload",
		grant = {
			project = owner.project,
			root = owner.root,
			path = owner.path,
			fileCabinetPath = fc,
			authId = authId,
			label = target.label,
			accountId = target.accountId,
			production = target.production,
			exp = 0,
		},
	}
end

local function openTarget(path: string, line: number?): string
	return path .. (if line then ":" .. line else "")
end

local function activate(s: State, row: Row?, effects: { Effect })
	local target = if row then row.target else nil
	if target == nil then
		return
	end
	if target.t == "detail" and target.root then
		s.detail = target.root
		s.tab = "projects"
		s.picking = false
	elseif target.t == "open" and target.path then
		table.insert(effects, { t = "open", target = openTarget(target.path, target.line) })
	elseif target.t == "upload" and target.owner then
		local e = grantFor(s, target.owner)
		if e then
			table.insert(effects, e)
		end
	end
end

local function upload(s: State, effects: { Effect })
	local row = M.selected(s)
	local owner = if row and row.target then row.target.owner else nil
	local e = if owner then grantFor(s, owner) else nil
	if e == nil then
		setNotice(s, "Select a File Cabinet file (in a project's detail) to upload it", "warning")
		return
	end
	table.insert(effects, e)
end

-- The project the selection is about, for `v`.
local function selectedProject(s: State): Types.Project?
	if s.detail and s.tab == "projects" and not s.picking then
		return Rows.project(s, s.detail)
	end
	local row = M.selected(s)
	local target = if row then row.target else nil
	if target == nil then
		return nil
	end
	if target.root then
		return Rows.project(s, target.root)
	end
	if target.owner then
		return Rows.project(s, target.owner.root)
	end
	if target.path then
		local best: Types.Project? = nil
		for _, p in s.projects do
			if string.sub(target.path, 1, #p.root + 1) == p.root .. "/" and (best == nil or #p.root > #best.root) then
				best = p
			end
		end
		return best
	end
	return nil
end

local function copyValidate(s: State, effects: { Effect })
	local p = selectedProject(s)
	if p == nil then
		setNotice(s, "Select a project to copy its validate command", "warning")
		return
	end
	local program = if s.config then s.config.suitecloud.program else "suitecloud"
	local text = "cd " .. Upload.quote(p.root) .. " && " .. Upload.quote(program) .. " project:validate"
	table.insert(effects, { t = "copy", text = text, note = "Copied: " .. text })
end

-- Keys ------------------------------------------------------------------------

local function printable(key: Key): string?
	if key.ctrl or key.meta or key.alt then
		return nil
	end
	local text = key.text
	if text and #text >= 1 and not string.find(text, "%c") then
		return text
	end
	if #key.name == 1 then
		return if key.shift then string.upper(key.name) else key.name
	end
	if key.name == "space" then
		return " "
	end
	return nil
end

local function setFilter(s: State, text: string)
	local vk = M.viewKey(s)
	if text == "" then
		s.filters[vk] = nil
	else
		s.filters[vk] = text
	end
	s.offset[vk] = nil
	local rows = M.rows(s)
	local i = M.selectedIndex(s, rows)
	if i > 0 then
		selectIndex(s, rows, i)
	end
end

local function editKey(s: State, key: Key, ch: string?): boolean
	local vk = M.viewKey(s)
	local name = key.name
	if name == "enter" or name == "return" then
		s.editing = false
	elseif name == "escape" then
		s.editing = false
		setFilter(s, "")
	elseif name == "backspace" then
		local f = s.filters[vk] or ""
		setFilter(s, string.sub(f, 1, -2))
	elseif name == "down" then
		move(s, 1)
	elseif name == "up" then
		move(s, -1)
	elseif ch then
		setFilter(s, (s.filters[vk] or "") .. ch)
	else
		return false
	end
	return true
end

local function onKey(s: State, key: Key, effects: { Effect }): boolean
	local ch = printable(key)
	if s.editing then
		return editKey(s, key, ch)
	end
	local name = key.name
	s.notice = nil
	if ch == "j" or name == "down" then
		move(s, 1)
	elseif ch == "k" or name == "up" then
		move(s, -1)
	elseif name == "pagedown" or name == "pageup" then
		local rows = M.rows(s)
		local first, last = M.window(s, rows, M.selectedIndex(s, rows))
		local page = math.max(1, last - first)
		move(s, if name == "pagedown" then page else -page)
	elseif name == "home" or ch == "g" then
		move(s, 0, 1)
	elseif name == "end" or ch == "G" then
		move(s, 0, -1)
	elseif name == "enter" or name == "return" then
		activate(s, M.selected(s), effects)
	elseif name == "backspace" then
		if s.picking then
			s.picking = false
		elseif s.tab == "projects" and s.detail then
			s.detail = nil
		else
			return false
		end
	elseif name == "tab" then
		s.picking = false
		s.tab = if s.tab == "projects" then "findings" else "projects"
	elseif ch == "/" then
		s.editing = true
	elseif ch == "r" then
		startScan(s, effects)
	elseif ch == "v" then
		copyValidate(s, effects)
	elseif ch == "u" then
		upload(s, effects)
	elseif name == "escape" then
		local vk = M.viewKey(s)
		if s.filters[vk] then
			setFilter(s, "")
		else
			table.insert(effects, { t = "exit" })
		end
	else
		return false
	end
	return true
end

local function onClick(s: State, value: string, effects: { Effect }): boolean
	local index, h = string.match(value, "^(%d+):(%x+)$")
	if index == nil or h == nil then
		return false
	end
	local rows = M.rows(s)
	local i = tonumber(index) :: number
	local r = rows[i]
	if r == nil or r.target == nil or hash(r.key) ~= h then
		return false
	end
	selectIndex(s, rows, i)
	activate(s, r, effects)
	return true
end

-- Update ------------------------------------------------------------------------

local function current(s: State, msg: Msg): boolean
	return msg.gen == s.gen
end

-- Applies `msg`; the state is updated in place. `changed` is false when the
-- message changed nothing (a stale answer or an unbound key).
function M.update(s: State, msg: Msg): (State, { Effect }, boolean)
	local effects: { Effect } = {}
	local t = msg.t
	if t == "config" then
		if not current(s, msg) or msg.config == nil then
			return s, effects, false
		end
		s.config = msg.config
		s.now = msg.now or s.now
		table.insert(effects, { t = "locate", gen = s.gen, cwd = s.cwd })
	elseif t == "located" then
		if not current(s, msg) or s.config == nil then
			return s, effects, false
		end
		local cfg = s.config
		s.repoRoot = msg.repoRoot
		s.projectRoot = msg.projectRoot
		local base = msg.repoRoot or (if msg.projectRoot then dirname(msg.projectRoot) else s.cwd)
		s.base = base
		local roots = if msg.repoRoot and cfg then table.clone(cfg.projects.roots) else {}
		table.insert(effects, { t = "discover", gen = s.gen, base = base, roots = roots })
	elseif t == "discovered" then
		if not current(s, msg) then
			return s, effects, false
		end
		onDiscovered(s, msg.roots or {}, msg.err, effects)
	elseif t == "scanned" then
		if not current(s, msg) or s.phase ~= "scanning" or msg.root ~= s.current then
			return s, effects, false
		end
		s.done += 1
		if msg.snapshot then
			table.insert(s.pending, Project.build(msg.snapshot))
		else
			table.insert(s.pendingErrors, { root = msg.root :: string, message = msg.err or "scan failed" })
		end
		if #s.queue > 0 then
			nextScan(s, effects)
		else
			finishScan(s, effects)
		end
	elseif t == "resolved" then
		local entry = msg.entry
		if entry == nil then
			return s, effects, false
		end
		s.inflight[entry.authId] = nil
		s.cache = Resolve.store(s.cache, entry)
		s.now = msg.now or s.now
		if s.pickPath then
			buildPick(s)
		end
	elseif t == "key" then
		if msg.key == nil then
			return s, effects, false
		end
		local handled = onKey(s, msg.key :: Key, effects)
		return s, effects, handled
	elseif t == "click" then
		return s, effects, onClick(s, msg.value or "", effects)
	elseif t == "resize" then
		s.height = msg.rows or s.height
		s.width = msg.cols or s.width
	end
	return s, effects, true
end

function M.title(s: State): string
	if s.picking and s.pickPath then
		return "Upload " .. (string.match(s.pickPath, "([^/]+)$") or s.pickPath)
	end
	local base = s.base or s.cwd
	return "SDF explorer · " .. (string.match(base, "([^/]+)$") or base)
end

return table.freeze(M)
